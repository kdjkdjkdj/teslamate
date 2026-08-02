defmodule Mix.Tasks.Fleet.Diff do
  use Mix.Task
  import Ecto.Query

  alias TeslaMate.FleetTelemetry.{ShadowPosition, ShadowCharge}
  alias TeslaMate.Log.{Drive, Position, ChargingProcess, Charge}
  alias TeslaMate.Repo

  @shortdoc "Diff Fleet-Telemetry shadow vs. polled data for a drive or charging process"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(args, strict: [drive: :integer, charging: :integer])

    cond do
      cp_id = opts[:charging] -> print_charging(cp_id, report(charging_process_id: cp_id))
      drive_id = opts[:drive] -> print_drive(drive_id, report(drive_id: drive_id))
      true -> Mix.raise("Usage: mix fleet.diff --drive <id> | --charging <charging_process_id>")
    end
  end

  defp print_drive(drive_id, r) do
    IO.puts("""
    Fleet-Telemetry Diff === drive #{drive_id}
      shadow points : #{r.shadow_count}
      poll points   : #{r.poll_count}
      max shadow gap: #{r.max_shadow_gap_s} s
      power samples : #{inspect(r.power_samples)}
    field coverage (% of shadow points with non-nil value):
    #{r.field_coverage |> Enum.map(fn {k, v} -> "  #{k}: #{v}%" end) |> Enum.join("\n")}
    """)
  end

  defp print_charging(cp_id, r) do
    IO.puts("""
    Fleet-Telemetry Diff === charging_process #{cp_id}
      shadow points : #{r.shadow_count}
      poll points   : #{r.poll_count}
      max shadow gap: #{r.max_shadow_gap_s} s
      charge_source : #{inspect(r.charge_sources)}
      state edges   : #{inspect(r.state_edges)}
      power samples : #{inspect(r.power_samples)}
    field coverage (% of shadow points with non-nil value):
    #{r.field_coverage |> Enum.map(fn {k, v} -> "  #{k}: #{v}%" end) |> Enum.join("\n")}
    """)
  end

  def report(opts) do
    cond do
      Keyword.has_key?(opts, :charging_process_id) ->
        charge_report(Keyword.fetch!(opts, :charging_process_id))

      true ->
        drive_report(Keyword.fetch!(opts, :drive_id))
    end
  end

  defp drive_report(drive_id) do
    drive = Repo.get!(Drive, drive_id)

    polls =
      Repo.all(from p in Position, where: p.drive_id == ^drive_id, order_by: p.date)

    shadows =
      Repo.all(
        from s in ShadowPosition,
          where:
            s.car_id == ^drive.car_id and s.date >= ^drive.start_date and
              s.date <= ^drive.end_date,
          order_by: s.date
      )

    %{
      shadow_count: length(shadows),
      poll_count: length(polls),
      max_shadow_gap_s: max_gap_s(shadows),
      field_coverage: field_coverage(shadows),
      power_samples: power_samples(shadows, polls)
    }
  end

  defp charge_report(cp_id) do
    cp = Repo.get!(ChargingProcess, cp_id)

    polls =
      Repo.all(from c in Charge, where: c.charging_process_id == ^cp_id, order_by: c.date)

    shadows =
      Repo.all(
        from s in ShadowCharge,
          where:
            s.car_id == ^cp.car_id and s.date >= ^cp.start_date and
              s.date <= ^cp.end_date,
          order_by: s.date
      )

    %{
      shadow_count: length(shadows),
      poll_count: length(polls),
      max_shadow_gap_s: max_gap_s(shadows),
      charge_sources: shadows |> Enum.map(& &1.charge_source) |> Enum.uniq(),
      state_edges: shadows |> Enum.map(& &1.charging_state) |> Enum.dedup(),
      field_coverage: charge_field_coverage(shadows),
      power_samples: charge_power_samples(shadows, polls)
    }
  end

  @charge_coverage_fields ~w(charger_power charger_voltage charger_actual_current
                             charge_energy_added usable_battery_level charging_state)a

  defp charge_field_coverage([]), do: Map.new(@charge_coverage_fields, &{&1, 0.0})

  defp charge_field_coverage(rows) do
    n = length(rows)

    Map.new(@charge_coverage_fields, fn f ->
      present = Enum.count(rows, &(not is_nil(Map.get(&1, f))))
      {f, Float.round(present * 100 / n, 1)}
    end)
  end

  defp charge_power_samples(shadows, polls) do
    for s <- shadows, s.charger_power != nil, p = nearest(polls, s.date), p != nil do
      {s.charger_power, p.charger_power}
    end
  end

  defp max_gap_s([]), do: 0
  defp max_gap_s([_]), do: 0

  defp max_gap_s(rows) do
    rows
    |> Enum.map(& &1.date)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> DateTime.diff(b, a) end)
    |> Enum.max(fn -> 0 end)
  end

  @coverage_fields ~w(latitude power speed battery_level rated_battery_range_km
                      outside_temp tpms_pressure_fl)a

  defp field_coverage([]), do: Map.new(@coverage_fields, &{&1, 0.0})

  defp field_coverage(rows) do
    n = length(rows)

    Map.new(@coverage_fields, fn f ->
      present = Enum.count(rows, &(not is_nil(Map.get(&1, f))))
      {f, Float.round(present * 100 / n, 1)}
    end)
  end

  defp power_samples(shadows, polls) do
    for s <- shadows, s.power != nil, p = nearest(polls, s.date), p != nil do
      {s.power, p.power}
    end
  end

  defp nearest([], _date), do: nil

  defp nearest(polls, date) do
    Enum.min_by(polls, &abs(DateTime.diff(&1.date, date)), fn -> nil end)
  end
end
