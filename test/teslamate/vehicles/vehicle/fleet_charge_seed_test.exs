defmodule TeslaMate.Vehicles.Vehicle.FleetChargeSeedTest do
  # Analog fleet_gear_seed_test.exs, aber fuer den Charge-Feed: seed_fleet_charge_state speist
  # den zuletzt gepollten charging_state als DetailedChargeState-Rohwert in den ChargeStreamProvider,
  # damit die Stopped-Kante nicht verpasst wird (onChange-Race).
  use ExUnit.Case, async: false

  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Vehicles.Vehicle.Data
  alias TeslaMate.Log.Car
  alias TeslaMate.FleetTelemetry.{StreamProvider, FieldState}

  setup do
    System.put_env("FLEET_TELEMETRY_FEED_CHARGING", "true")
    System.put_env("FLEET_TELEMETRY_VIN", "CSEEDVIN")

    on_exit(fn ->
      System.delete_env("FLEET_TELEMETRY_FEED_CHARGING")
      System.delete_env("FLEET_TELEMETRY_VIN")
    end)

    :ok
  end

  defp start_provider do
    {:ok, sp} =
      StreamProvider.start_link(
        car_id: 1,
        vin: "CSEEDVIN",
        receiver: fn _ -> :ok end,
        trigger_field: "DetailedChargeState",
        map_fun: fn fields, _ -> Map.get(fields, "DetailedChargeState") end,
        connect?: false
      )

    on_exit(fn -> StreamProvider.stop(sp) end)
    sp
  end

  # Deterministisch (kein Sleep): der cast und dieses :sys.get_state kommen beide vom Test-Prozess.
  defp detailed(sp), do: FieldState.get(:sys.get_state(sp).state, "DetailedChargeState")

  test "seed_fleet_charge_state speist den DetailedChargeState-Rohwert in den Provider" do
    sp = start_provider()
    data = %Data{car: %Car{vin: "CSEEDVIN"}, charge_stream_pid: sp}

    assert :ok = Vehicle.seed_fleet_charge_state(data, "Charging")
    assert detailed(sp) == "DetailedChargeStateCharging"
  end

  test "seed_fleet_charge_state mappt die Stopped-Kante korrekt" do
    sp = start_provider()
    data = %Data{car: %Car{vin: "CSEEDVIN"}, charge_stream_pid: sp}

    assert :ok = Vehicle.seed_fleet_charge_state(data, "Stopped")
    assert detailed(sp) == "DetailedChargeStateStopped"
  end

  test "no-op wenn der Charge-Feed aus ist" do
    System.delete_env("FLEET_TELEMETRY_FEED_CHARGING")
    sp = start_provider()
    data = %Data{car: %Car{vin: "CSEEDVIN"}, charge_stream_pid: sp}

    assert :ok = Vehicle.seed_fleet_charge_state(data, "Charging")
    assert detailed(sp) == nil
  end

  test "no-op ohne ChargeStreamProvider (charge_stream_pid nil)" do
    data = %Data{car: %Car{vin: "CSEEDVIN"}, charge_stream_pid: nil}
    assert :ok = Vehicle.seed_fleet_charge_state(data, "Charging")
  end

  test "unbekannter charging_state seedet nichts (kein Garbage)" do
    sp = start_provider()
    data = %Data{car: %Car{vin: "CSEEDVIN"}, charge_stream_pid: sp}

    assert :ok = Vehicle.seed_fleet_charge_state(data, "Quatsch")
    assert detailed(sp) == nil
  end
end
