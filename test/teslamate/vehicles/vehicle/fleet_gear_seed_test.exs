defmodule TeslaMate.Vehicles.Vehicle.FleetGearSeedTest do
  use ExUnit.Case, async: false

  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Vehicles.Vehicle.Data
  alias TeslaMate.Log.Car
  alias TeslaMate.FleetTelemetry.{StreamProvider, FieldState}

  setup do
    System.put_env("FLEET_TELEMETRY_FEED", "true")
    System.put_env("FLEET_TELEMETRY_VIN", "SEEDVIN")

    on_exit(fn ->
      System.delete_env("FLEET_TELEMETRY_FEED")
      System.delete_env("FLEET_TELEMETRY_VIN")
    end)

    :ok
  end

  defp start_provider do
    {:ok, sp} =
      StreamProvider.start_link(
        car_id: 1,
        vin: "SEEDVIN",
        receiver: fn _ -> :ok end,
        connect?: false
      )

    on_exit(fn -> StreamProvider.stop(sp) end)
    sp
  end

  # Der cast von seed_fleet_gear und dieses :sys.get_state kommen beide vom
  # Test-Prozess -> Nachrichten-Reihenfolge bleibt erhalten, der Ingest ist
  # verarbeitet, wenn get_state zurueckkommt (deterministisch, kein Sleep).
  defp gear(sp), do: FieldState.get(:sys.get_state(sp).state, "Gear")

  test "seed_fleet_gear speist den aktuellen Gang in den laufenden StreamProvider" do
    sp = start_provider()
    data = %Data{car: %Car{vin: "SEEDVIN"}, stream_pid: sp}

    assert :ok = Vehicle.seed_fleet_gear(data, "D")
    assert gear(sp) == "ShiftStateD"
  end

  test "seed_fleet_gear mappt R korrekt (nicht nur D)" do
    sp = start_provider()
    data = %Data{car: %Car{vin: "SEEDVIN"}, stream_pid: sp}

    assert :ok = Vehicle.seed_fleet_gear(data, "R")
    assert gear(sp) == "ShiftStateR"
  end

  test "seed_fleet_gear tut nichts, wenn der Feed aus ist" do
    System.delete_env("FLEET_TELEMETRY_FEED")
    sp = start_provider()
    data = %Data{car: %Car{vin: "SEEDVIN"}, stream_pid: sp}

    assert :ok = Vehicle.seed_fleet_gear(data, "D")
    assert gear(sp) == nil
  end

  test "seed_fleet_gear crasht nicht ohne StreamProvider (stream_pid nil)" do
    data = %Data{car: %Car{vin: "SEEDVIN"}, stream_pid: nil}
    assert :ok = Vehicle.seed_fleet_gear(data, "D")
  end

  describe "seed_fleet_odometer/2" do
    defp odo(sp), do: FieldState.get(:sys.get_state(sp).state, "Odometer")

    defp vehicle_with_odometer(odo) do
      %TeslaApi.Vehicle{
        vehicle_state: %TeslaApi.Vehicle.State.VehicleState{odometer: odo}
      }
    end

    test "speist den zuletzt gepollten Kilometerstand in den StreamProvider (Meilen, unveraendert)" do
      sp = start_provider()
      data = %Data{car: %Car{vin: "SEEDVIN"}, stream_pid: sp}

      assert :ok = Vehicle.seed_fleet_odometer(data, vehicle_with_odometer(64_373.32286986481))
      assert odo(sp) == 64_373.32286986481
    end

    test "ein echtes Odometer-Event ueberschreibt den Seed" do
      sp = start_provider()
      data = %Data{car: %Car{vin: "SEEDVIN"}, stream_pid: sp}

      assert :ok = Vehicle.seed_fleet_odometer(data, vehicle_with_odometer(1.0))
      StreamProvider.ingest(sp, "Odometer", 2.0)
      assert odo(sp) == 2.0
    end

    test "tut nichts, wenn der Feed aus ist" do
      System.delete_env("FLEET_TELEMETRY_FEED")
      sp = start_provider()
      data = %Data{car: %Car{vin: "SEEDVIN"}, stream_pid: sp}

      assert :ok = Vehicle.seed_fleet_odometer(data, vehicle_with_odometer(64_373.0))
      assert odo(sp) == nil
    end

    test "ignoriert einen fehlenden Kilometerstand statt zu crashen" do
      sp = start_provider()
      data = %Data{car: %Car{vin: "SEEDVIN"}, stream_pid: sp}

      assert :ok = Vehicle.seed_fleet_odometer(data, vehicle_with_odometer(nil))
      assert :ok = Vehicle.seed_fleet_odometer(data, %TeslaApi.Vehicle{})
      assert odo(sp) == nil
    end

    test "crasht nicht ohne StreamProvider (stream_pid nil)" do
      data = %Data{car: %Car{vin: "SEEDVIN"}, stream_pid: nil}
      assert :ok = Vehicle.seed_fleet_odometer(data, vehicle_with_odometer(64_373.0))
    end
  end
end
