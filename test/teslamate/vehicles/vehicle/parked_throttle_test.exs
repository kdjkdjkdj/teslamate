defmodule TeslaMate.Vehicles.Vehicle.ParkedThrottleTest do
  # Pure Unit-Tests fuer die Poll-Drosselung des wachen, parkenden Autos. Eigene Datei
  # (statt VehicleCase) wie charge_throttle_test.exs, damit die FLEET_TELEMETRY_*-Env-
  # Manipulation nicht in die Integrationstests blutet.
  use ExUnit.Case, async: false

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

  defp covered_data do
    %Data{
      car: %Car{vin: "PARKVIN"},
      stream_pid: self(),
      charge_watch_pid: self()
    }
  end

  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    pid
  end

  describe "parked_poll_interval/2 - gedrosselt, wenn uns jemand wecken wuerde" do
    test "beide Dauer-Abonnenten leben: Default 300 s" do
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
