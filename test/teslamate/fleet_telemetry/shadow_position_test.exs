defmodule TeslaMate.FleetTelemetry.ShadowPositionTest do
  use TeslaMate.DataCase, async: true

  alias TeslaMate.FleetTelemetry.ShadowPosition

  test "inserts a valid shadow position with mapped columns" do
    attrs = %{
      car_id: 1,
      date: ~U[2026-06-23 10:08:24.000000Z],
      latitude: Decimal.new("48.396021"),
      longitude: Decimal.new("10.860954"),
      speed: 76,
      power: -54,
      battery_level: 64,
      power_source: "packvi_proxy",
      fields_present: 12,
      max_field_age_s: 4
    }

    assert {:ok, row} = %ShadowPosition{} |> ShadowPosition.changeset(attrs) |> Repo.insert()
    assert row.car_id == 1
    assert row.power == -54
    assert row.power_source == "packvi_proxy"
  end

  test "requires car_id and date" do
    changeset = ShadowPosition.changeset(%ShadowPosition{}, %{})
    refute changeset.valid?
    assert %{car_id: ["can't be blank"], date: ["can't be blank"]} = errors_on(changeset)
  end
end
