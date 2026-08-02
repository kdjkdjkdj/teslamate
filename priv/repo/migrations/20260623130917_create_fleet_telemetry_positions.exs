defmodule TeslaMate.Repo.Migrations.CreateFleetTelemetryPositions do
  use Ecto.Migration

  def change do
    create table(:fleet_telemetry_positions) do
      add :car_id, :integer, null: false
      add :date, :utc_datetime_usec, null: false

      add :latitude, :decimal
      add :longitude, :decimal
      add :elevation, :integer
      add :speed, :integer
      add :power, :integer
      add :odometer, :float

      add :battery_level, :integer
      add :usable_battery_level, :integer
      add :rated_battery_range_km, :decimal
      add :ideal_battery_range_km, :decimal
      add :est_battery_range_km, :decimal

      add :outside_temp, :decimal
      add :inside_temp, :decimal
      add :is_climate_on, :boolean
      add :is_front_defroster_on, :boolean
      add :is_rear_defroster_on, :boolean
      add :fan_status, :integer
      add :battery_heater_on, :boolean

      add :tpms_pressure_fl, :decimal
      add :tpms_pressure_fr, :decimal
      add :tpms_pressure_rl, :decimal
      add :tpms_pressure_rr, :decimal

      add :fields_present, :integer
      add :max_field_age_s, :integer
      add :power_source, :string

      timestamps(updated_at: false)
    end

    create index(:fleet_telemetry_positions, [:car_id, :date])
  end
end
