defmodule TeslaMate.Repo.Migrations.CreateFleetTelemetryCharges do
  use Ecto.Migration

  def change do
    create table(:fleet_telemetry_charges) do
      add :car_id, :integer, null: false
      add :date, :utc_datetime_usec, null: false

      add :charging_state, :string
      add :charge_source, :string

      add :charger_power, :integer
      add :charger_voltage, :integer
      add :charger_actual_current, :integer
      add :charger_phases, :integer
      add :charge_energy_added, :decimal

      add :battery_level, :integer
      add :usable_battery_level, :integer
      add :ideal_battery_range_km, :decimal
      add :rated_battery_range_km, :decimal

      add :fast_charger_present, :boolean
      add :fast_charger_type, :string

      add :fields_present, :integer
      add :max_field_age_s, :integer

      timestamps(updated_at: false)
    end

    create index(:fleet_telemetry_charges, [:car_id, :date])
  end
end
