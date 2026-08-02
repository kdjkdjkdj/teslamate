defmodule TeslaMate.FleetTelemetry.ShadowPosition do
  use Ecto.Schema
  import Ecto.Changeset

  @fields ~w(
    car_id date latitude longitude elevation speed power odometer
    battery_level usable_battery_level rated_battery_range_km
    ideal_battery_range_km est_battery_range_km outside_temp inside_temp
    is_climate_on is_front_defroster_on is_rear_defroster_on fan_status
    battery_heater_on tpms_pressure_fl tpms_pressure_fr tpms_pressure_rl
    tpms_pressure_rr fields_present max_field_age_s power_source
  )a

  schema "fleet_telemetry_positions" do
    field :car_id, :integer
    field :date, :utc_datetime_usec
    field :latitude, :decimal
    field :longitude, :decimal
    field :elevation, :integer
    field :speed, :integer
    field :power, :integer
    field :odometer, :float
    field :battery_level, :integer
    field :usable_battery_level, :integer
    field :rated_battery_range_km, :decimal
    field :ideal_battery_range_km, :decimal
    field :est_battery_range_km, :decimal
    field :outside_temp, :decimal
    field :inside_temp, :decimal
    field :is_climate_on, :boolean
    field :is_front_defroster_on, :boolean
    field :is_rear_defroster_on, :boolean
    field :fan_status, :integer
    field :battery_heater_on, :boolean
    field :tpms_pressure_fl, :decimal
    field :tpms_pressure_fr, :decimal
    field :tpms_pressure_rl, :decimal
    field :tpms_pressure_rr, :decimal
    field :fields_present, :integer
    field :max_field_age_s, :integer
    field :power_source, :string

    timestamps(updated_at: false)
  end

  def changeset(position, attrs) do
    position
    |> cast(attrs, @fields)
    |> validate_required([:car_id, :date])
  end
end
