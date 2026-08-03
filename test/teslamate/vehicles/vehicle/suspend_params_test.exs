defmodule TeslaMate.Vehicles.Vehicle.SuspendParamsTest do
  use ExUnit.Case, async: false

  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Vehicles.Vehicle.Data
  alias TeslaMate.Log.Car
  alias TeslaMate.Settings.CarSettings
  alias TeslaMate.FleetTelemetry.StreamProvider

  @settings %CarSettings{use_streaming_api: true, suspend_after_idle_min: 15, suspend_min: 12}

  defp fleet_env(on?) do
    if on? do
      System.put_env("FLEET_TELEMETRY_FEED", "true")
      System.put_env("FLEET_TELEMETRY_VIN", "SUSPVIN")
    else
      System.delete_env("FLEET_TELEMETRY_FEED")
      System.delete_env("FLEET_TELEMETRY_VIN")
    end
  end

  setup do
    on_exit(fn -> fleet_env(false) end)
    :ok
  end

  defp start_provider do
    {:ok, sp} =
      StreamProvider.start_link(
        car_id: 1,
        vin: "SUSPVIN",
        receiver: fn _ -> :ok end,
        connect?: false
      )

    on_exit(fn -> StreamProvider.stop(sp) end)
    sp
  end

  defp data(opts) do
    %Data{
      car: %Car{vin: "SUSPVIN", settings: Keyword.get(opts, :settings, @settings)},
      stream_pid: Keyword.get(opts, :stream_pid),
      last_stream_at: Keyword.get(opts, :last_stream_at)
    }
  end

  describe "Fleet-Feed aktiv" do
    test "frischer Feed: Upstream-Werte, der Stream weckt" do
      fleet_env(true)
      sp = start_provider()
      d = data(stream_pid: sp, last_stream_at: DateTime.utc_now())

      assert Vehicle.suspend_params(d) == {3, 30, 2}
    end

    test "stiller Feed: Eile bleibt, nur die Dauer wird gekappt" do
      fleet_env(true)
      sp = start_provider()
      # Telemetrie aelter als das Freshness-Fenster (30 s)
      stale = DateTime.add(DateTime.utc_now(), -120, :second)
      d = data(stream_pid: sp, last_stream_at: stale)

      # 3 min Leerlauf und Multiplikator 2 wie vorher (~6 Polls), Dauer aus den
      # Fahrzeugeinstellungen statt blind 30 min
      assert Vehicle.suspend_params(d) == {3, 12, 2}
    end

    test "nie Telemetrie gesehen: ebenfalls gekappte Dauer" do
      fleet_env(true)
      sp = start_provider()
      d = data(stream_pid: sp, last_stream_at: nil)

      assert Vehicle.suspend_params(d) == {3, 12, 2}
    end

    test "kein Provider-Prozess: gekappte Dauer" do
      fleet_env(true)
      d = data(stream_pid: nil, last_stream_at: DateTime.utc_now())

      assert Vehicle.suspend_params(d) == {3, 12, 2}
    end
  end

  describe "ohne Fleet-Feed bleibt Upstream unangetastet" do
    test "use_streaming_api mit totem Stream: Fahrzeugeinstellungen" do
      fleet_env(false)
      d = data(stream_pid: nil, last_stream_at: nil)

      assert Vehicle.suspend_params(d) == {15, 12, 1}
    end

    test "use_streaming_api mit lebendigem Stream: Upstream-Werte" do
      fleet_env(false)
      sp = start_provider()
      d = data(stream_pid: sp, last_stream_at: DateTime.utc_now())

      assert Vehicle.suspend_params(d) == {3, 30, 2}
    end

    test "Streaming abgeschaltet: Fahrzeugeinstellungen" do
      fleet_env(false)
      settings = %CarSettings{@settings | use_streaming_api: false}
      d = data(settings: settings, stream_pid: nil)

      assert Vehicle.suspend_params(d) == {15, 12, 1}
    end
  end
end
