defmodule TeslaMate.FleetTelemetry.ShadowCharge do
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(
    car_id date charging_state charge_source
    charger_power charger_voltage charger_actual_current charger_phases
    charge_energy_added battery_level usable_battery_level
    ideal_battery_range_km rated_battery_range_km
    fast_charger_present fast_charger_type
    fields_present max_field_age_s
  )a

  schema "fleet_telemetry_charges" do
    field :car_id, :integer
    field :date, :utc_datetime_usec
    field :charging_state, :string
    field :charge_source, :string
    field :charger_power, :integer
    field :charger_voltage, :integer
    field :charger_actual_current, :integer
    field :charger_phases, :integer
    field :charge_energy_added, :decimal
    field :battery_level, :integer
    field :usable_battery_level, :integer
    field :ideal_battery_range_km, :decimal
    field :rated_battery_range_km, :decimal
    field :fast_charger_present, :boolean
    field :fast_charger_type, :string
    field :fields_present, :integer
    field :max_field_age_s, :integer

    timestamps(updated_at: false)
  end

  def changeset(charge, attrs) do
    charge
    |> cast(attrs, @fields)
    |> validate_required([:car_id, :date])
  end
end
