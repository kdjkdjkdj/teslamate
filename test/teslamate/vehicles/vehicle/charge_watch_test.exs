defmodule TeslaMate.Vehicles.Vehicle.ChargeWatchTest do
  use TeslaMate.VehicleCase, async: false

  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Vehicles.Vehicle.{Data, Summary}
  alias TeslaMate.Log.Car

  describe "charge_watch_enabled?/1" do
    defp data_for(vin), do: %Data{car: %Car{vin: vin}}

    setup do
      on_exit(fn ->
        System.delete_env("FLEET_TELEMETRY_CHARGE_WATCH")
        System.delete_env("FLEET_TELEMETRY_VIN")
      end)

      :ok
    end

    test "aus, solange der Flag fehlt" do
      System.put_env("FLEET_TELEMETRY_VIN", "WATCHVIN")
      refute Vehicle.charge_watch_enabled?(data_for("WATCHVIN"))
    end

    test "an bei Flag und passender VIN" do
      System.put_env("FLEET_TELEMETRY_CHARGE_WATCH", "true")
      System.put_env("FLEET_TELEMETRY_VIN", "WATCHVIN")
      assert Vehicle.charge_watch_enabled?(data_for("WATCHVIN"))
    end

    test "aus bei fremder VIN - schuetzt Mehr-Fahrzeug-Setups" do
      System.put_env("FLEET_TELEMETRY_CHARGE_WATCH", "true")
      System.put_env("FLEET_TELEMETRY_VIN", "WATCHVIN")
      refute Vehicle.charge_watch_enabled?(data_for("ANDERE"))
    end

    test "aus ohne VIN" do
      System.put_env("FLEET_TELEMETRY_CHARGE_WATCH", "true")
      System.put_env("FLEET_TELEMETRY_VIN", "WATCHVIN")
      refute Vehicle.charge_watch_enabled?(data_for(nil))
    end
  end

  describe "Weckpfad aus dem Suspend" do
    # Der Suspend-Zustand ignoriert ein {:online, %Vehicle{}} bewusst, und der Fahr-Feed
    # triggert auf `Location` - die ein parkendes Auto nie sendet. Ohne diesen Weckpfad
    # blieb eine im Stand beginnende Ladung bis zum Ende des Suspend-Fensters unerfasst.
    defp suspendable(ts) do
      online_event(ts,
        drive_state: %{timestamp: ts, latitude: 0.0, longitude: 0.0},
        climate_state: %{is_preconditioning: false}
      )
    end

    defp start_suspended(name) do
      now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      events =
        Enum.map(0..11, fn i -> {:ok, suspendable(now_ts + i)} end) ++
          [fn -> Process.sleep(10_000) end]

      :ok = start_vehicle(name, events)

      assert_receive {:start_state, car, :online, date: _}
      assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}
      assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :suspended}}}, 2_000

      car
    end

    @tag :capture_log
    test "ein Ladebeginn verlaesst den Suspend", %{test: name} do
      _car = start_suspended(name)

      send(name, {:charge_watch, "DetailedChargeStateCharging"})

      assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}, 1_000
    end

    @tag :capture_log
    test "auch die Starting-Kante weckt", %{test: name} do
      _car = start_suspended(name)

      send(name, {:charge_watch, "DetailedChargeStateStarting"})

      assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}, 1_000
    end

    @tag :capture_log
    test "eine andere Phase weckt NICHT", %{test: name} do
      _car = start_suspended(name)

      send(name, {:charge_watch, "DetailedChargeStateDisconnected"})

      refute_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}, 300
    end

    @tag :capture_log
    test "das Freshness-Signal des Providers weckt NICHT", %{test: name} do
      _car = start_suspended(name)

      # Der Provider sendet nach jedem Emit ein :fleet_streaming nach; der Waechter-Receiver
      # verpackt es als {:charge_watch, :fleet_streaming}.
      send(name, {:charge_watch, :fleet_streaming})

      refute_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}, 300
    end
  end
end
