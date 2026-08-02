defmodule TeslaMate.FleetTelemetry.BackfillMarker do
  @moduledoc """
  Idempotenz-Marker fuer den Charge-Backfill: haelt fest, welche Shadow-Ladesession
  (car_id + Zeitfenster) bereits als `charging_process` nachgetragen wurde, damit ein
  erneuter Scan sie nicht doppelt anlegt.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "fleet_telemetry_backfills" do
    field :car_id, :integer
    field :session_start, :utc_datetime_usec
    field :session_end, :utc_datetime_usec
    field :charging_process_id, :integer
    timestamps(updated_at: false)
  end

  @fields ~w(car_id session_start session_end charging_process_id)a
  def changeset(marker, attrs) do
    marker
    |> cast(attrs, @fields)
    |> validate_required([:car_id, :session_start, :session_end])
  end
end
