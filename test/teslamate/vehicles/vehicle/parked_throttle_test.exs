defmodule TeslaMate.Vehicles.Vehicle.ParkedThrottleTest do
  # Pure Unit-Tests fuer die Poll-Drosselung des wachen, parkenden Autos. Eigene Datei
  # (statt VehicleCase) wie charge_throttle_test.exs, damit die FLEET_TELEMETRY_*-Env-
  # Manipulation nicht in die Integrationstests blutet.
  #
  # ⚠️ Die Abdeckung wird mit ECHTEN StreamProvider-Prozessen geprueft, nicht mit self():
  # fleet_parked_covered?/1 fragt den Provider per GenServer.call nach seinem
  # Verbindungsstatus - mit self() als Pid wuerde der Test sich selbst anrufen.
  use ExUnit.Case, async: false

  alias TeslaMate.FleetTelemetry.StreamProvider
  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Vehicles.Vehicle.Data
  alias TeslaMate.Log.Car

  setup do
    System.put_env("FLEET_TELEMETRY_FEED", "true")
    System.put_env("FLEET_TELEMETRY_CHARGE_WATCH", "true")
    System.put_env("FLEET_TELEMETRY_VIN", "PARKVIN")

    on_exit(fn ->
      System.delete_env("FLEET_TELEMETRY_FEED")
      System.delete_env("FLEET_TELEMETRY_CHARGE_WATCH")
      System.delete_env("FLEET_TELEMETRY_VIN")
      System.delete_env("POLLING_FLEET_PARKED_INTERVAL")
    end)

    :ok
  end

  defp provider(connected?) do
    {:ok, pid} =
      StreamProvider.start_link(
        car_id: 1,
        vin: "PARKVIN",
        receiver: fn _ -> :ok end,
        connect?: false
      )

    on_exit(fn -> StreamProvider.stop(pid) end)

    if connected? do
      StreamProvider.mark_connection(pid, :up)
      assert StreamProvider.connected?(pid)
    end

    pid
  end

  defp covered_data do
    %Data{
      car: %Car{vin: "PARKVIN"},
      stream_pid: provider(true),
      charge_watch_pid: provider(true)
    }
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    pid
  end

  describe "parked_poll_interval/2 - gedrosselt, wenn uns jemand wecken wuerde" do
    test "beide Dauer-Abonnenten leben und sind verbunden: Default 300 s" do
      assert Vehicle.parked_poll_interval(covered_data(), 15) == 300
    end

    test "ehrt POLLING_FLEET_PARKED_INTERVAL" do
      System.put_env("POLLING_FLEET_PARKED_INTERVAL", "600")
      assert Vehicle.parked_poll_interval(covered_data(), 15) == 600
    end

    test "ein kleinerer Umgebungswert wird auf den Default angehoben" do
      # interval/2 nimmt max(env, default) - der Default ist eine Untergrenze, keine
      # Vorbelegung. Wer schneller pollen will, muss den Default aendern, nicht die Env.
      System.put_env("POLLING_FLEET_PARKED_INTERVAL", "120")
      assert Vehicle.parked_poll_interval(covered_data(), 15) == 300
    end

    test "die Drosselung haengt NICHT an der Feed-Frische" do
      # Ein parkendes Auto sendet keine Location - der Fahr-Feed ist hier per Design still.
      # Wuerde die Drosselung an fleet_stream_active?/1 haengen, waere sie genau dort inert,
      # wo sie gebraucht wird. last_stream_at bleibt deshalb bewusst nil.
      data = %{covered_data() | last_stream_at: nil}
      assert Vehicle.parked_poll_interval(data, 15) == 300
    end

    test "nie schneller als Upstream: ein groesserer Fallback gewinnt" do
      assert Vehicle.parked_poll_interval(covered_data(), 900) == 900
    end
  end

  describe "parked_poll_interval/2 - unveraendert ohne Weckabdeckung" do
    test "Fahr-Feed-Flag aus" do
      System.delete_env("FLEET_TELEMETRY_FEED")
      assert Vehicle.parked_poll_interval(covered_data(), 15) == 15
    end

    test "Ladewaechter-Flag aus - sonst bliebe ein Ladebeginn bis zu 5 min unbemerkt" do
      System.delete_env("FLEET_TELEMETRY_CHARGE_WATCH")
      assert Vehicle.parked_poll_interval(covered_data(), 15) == 15
    end

    test "fremde VIN" do
      data = %{covered_data() | car: %Car{vin: "ANDERE"}}
      assert Vehicle.parked_poll_interval(data, 15) == 15
    end

    test "kein Fahr-Provider" do
      data = %{covered_data() | stream_pid: nil}
      assert Vehicle.parked_poll_interval(data, 15) == 15
    end

    test "kein Ladewaechter-Prozess" do
      data = %{covered_data() | charge_watch_pid: nil}
      assert Vehicle.parked_poll_interval(data, 15) == 15
    end

    test "toter Fahr-Provider" do
      data = %{covered_data() | stream_pid: dead_pid()}
      assert Vehicle.parked_poll_interval(data, 15) == 15
    end

    test "toter Ladewaechter" do
      data = %{covered_data() | charge_watch_pid: dead_pid()}
      assert Vehicle.parked_poll_interval(data, 15) == 15
    end
  end

  describe "parked_poll_interval/2 - lebendig ist nicht verbunden" do
    # Der StreamProvider ueberlebt einen Stall absichtlich: bricht die MQTT-Strecke weg,
    # lebt der Prozess weiter und Process.alive?/1 meldet weiter true. Genau dann wuerde
    # uns aber niemand mehr wecken - also darf auch nicht gedrosselt werden.
    test "Fahr-Provider lebt, ist aber nicht verbunden" do
      data = %{covered_data() | stream_pid: provider(false)}
      assert Vehicle.parked_poll_interval(data, 15) == 15
    end

    test "Ladewaechter lebt, ist aber nicht verbunden" do
      data = %{covered_data() | charge_watch_pid: provider(false)}
      assert Vehicle.parked_poll_interval(data, 15) == 15
    end

    test "Verbindung faellt weg -> Drosselung endet sofort" do
      data = covered_data()
      assert Vehicle.parked_poll_interval(data, 15) == 300

      StreamProvider.mark_connection(data.stream_pid, :down)
      assert Vehicle.parked_poll_interval(data, 15) == 15
    end

    test "Verbindung kommt zurueck -> Drosselung greift wieder" do
      data = %{covered_data() | stream_pid: provider(false)}
      assert Vehicle.parked_poll_interval(data, 15) == 15

      StreamProvider.mark_connection(data.stream_pid, :up)
      assert Vehicle.parked_poll_interval(data, 15) == 300
    end
  end

  describe "fleet_parked_interval/0" do
    test "Default 300 s" do
      assert Vehicle.fleet_parked_interval() == 300
    end

    test "aus der Umgebung" do
      System.put_env("POLLING_FLEET_PARKED_INTERVAL", "900")
      assert Vehicle.fleet_parked_interval() == 900
    end
  end
end
