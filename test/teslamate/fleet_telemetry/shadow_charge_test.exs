defmodule TeslaMate.FleetTelemetry.ShadowChargeTest do
  use TeslaMate.DataCase, async: true

  alias TeslaMate.FleetTelemetry.ShadowCharge

  test "inserts a valid shadow charge with mapped columns" do
    attrs = %{
      car_id: 1,
      date: ~U[2026-06-23 10:08:24.000000Z],
      charging_state: "DetailedChargeStateCharging",
      charge_source: "dc",
      charger_power: 67,
      charger_voltage: 391,
      charger_actual_current: 138,
      charger_phases: 1,
      charge_energy_added: Decimal.new("12.34"),
      battery_level: 64,
      usable_battery_level: 63,
      fields_present: 12,
      max_field_age_s: 5
    }

    assert {:ok, row} = %ShadowCharge{} |> ShadowCharge.changeset(attrs) |> Repo.insert()
    assert row.car_id == 1
    assert row.charger_power == 67
    assert row.charge_source == "dc"
    assert row.charging_state == "DetailedChargeStateCharging"
  end

  test "requires car_id and date" do
    changeset = ShadowCharge.changeset(%ShadowCharge{}, %{})
    refute changeset.valid?
    assert %{car_id: ["can't be blank"], date: ["can't be blank"]} = errors_on(changeset)
  end
end
