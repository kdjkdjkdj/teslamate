defmodule TeslaMate.Repo.Migrations.CreateFleetTelemetryBackfills do
  use Ecto.Migration

  def change do
    create table(:fleet_telemetry_backfills) do
      add :car_id, :integer, null: false
      add :session_start, :utc_datetime_usec, null: false
      add :session_end, :utc_datetime_usec, null: false
      add :charging_process_id, references(:charging_processes, on_delete: :delete_all)
      timestamps(updated_at: false)
    end

    create index(:fleet_telemetry_backfills, [:car_id, :session_start])
  end
end
