defmodule TeslaMate.Repo.Migrations.AddSucCostSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      add :suc_cost_basis, :string, null: false, default: "gross"
      add :suc_sync_interval_hours, :integer, null: false, default: 24
      add :suc_giveup_window_days, :integer, null: false, default: 14
    end
  end
end
