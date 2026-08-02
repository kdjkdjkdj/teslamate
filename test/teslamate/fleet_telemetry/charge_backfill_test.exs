defmodule TeslaMate.FleetTelemetry.ChargeBackfillTest do
  use TeslaMate.DataCase

  alias TeslaMate.FleetTelemetry.ChargeBackfill
  alias TeslaMate.FleetTelemetry.{ShadowCharge, BackfillMarker}
  alias TeslaMate.Log
  alias TeslaMate.Log.{ChargingProcess, Position}
  import Ecto.Query

  test "trigger ist no-op, wenn der GenServer nicht laeuft" do
    assert ChargeBackfill.trigger(1) == :ok
  end

  test "scan rekonstruiert eine verpasste Session und ist idempotent" do
    {:ok, car} = Log.create_car(%{eid: 42, vid: 42, vin: "TESTVIN0000000042"})
    now = DateTime.utc_now()

    # Zusammenhaengende Shadow-Session (Abstaende < 20 min), Energie 0 -> 25 kWh
    insert_shadow(car.id, DateTime.add(now, -60 * 60), 27, "0.0")
    insert_shadow(car.id, DateTime.add(now, -45 * 60), 45, "12.0")
    insert_shadow(car.id, DateTime.add(now, -30 * 60), 63, "25.0")
    # Ladeort-Position kurz nach Session-Ende
    Repo.insert!(%Position{
      car_id: car.id,
      date: DateTime.add(now, -25 * 60),
      latitude: 48.871983,
      longitude: 9.346409
    })

    deps = test_deps()

    assert :ok = ChargeBackfill.scan(car.id, deps)
    cps = Repo.all(from c in ChargingProcess, where: c.car_id == ^car.id)
    assert length(cps) == 1
    cp = hd(cps)
    assert Decimal.equal?(cp.charge_energy_added, Decimal.new("25.00"))
    assert cp.start_battery_level == 27 and cp.end_battery_level == 63
    assert Repo.aggregate(BackfillMarker, :count) == 1

    # zweiter Lauf legt nichts Neues an (Marker + Ueberlappung)
    assert :ok = ChargeBackfill.scan(car.id, deps)
    assert length(Repo.all(from c in ChargingProcess, where: c.car_id == ^car.id)) == 1
    assert Repo.aggregate(BackfillMarker, :count) == 1
  end

  defp insert_shadow(car_id, date, bl, kwh) do
    %ShadowCharge{}
    |> ShadowCharge.changeset(%{
      car_id: car_id,
      date: date,
      battery_level: bl,
      usable_battery_level: bl,
      charge_energy_added: Decimal.new(kwh),
      charger_power: 11,
      charger_voltage: 224,
      charger_actual_current: 16,
      charger_phases: 2,
      ideal_battery_range_km: Decimal.new("129.0"),
      rated_battery_range_km: Decimal.new("129.0"),
      charging_state: "DetailedChargeStateCharging"
    })
    |> Repo.insert!()
  end

  # Echte Log-Anlage, aber ohne Geocoding (kein Netz-Call im Test).
  defp test_deps do
    %{
      log: %{
        start_charging_process: fn car, pos, _opts ->
          Log.start_charging_process(car, pos, lookup_address: false)
        end,
        insert_charge: &Log.insert_charge/2,
        complete_charging_process: &Log.complete_charging_process/1
      }
    }
  end
end
