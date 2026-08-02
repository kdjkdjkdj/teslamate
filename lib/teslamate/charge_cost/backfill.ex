defmodule TeslaMate.ChargeCost.Backfill do
  @moduledoc """
  Einmaliger Backfill der SuC-Kosten ueber einen Zeitraum.

  Matcht SuC-Ladungen gegen die Fleet-Charging-History und schreibt `cost` bei
  noch unbekosteten Ladungen. Bereits bekostete Ladungen werden weiterhin
  gematcht (ohne erneuten Write), damit ihre Sessions nicht faelschlich als
  Orphans gelten. Optional werden Sessions ohne passenden TeslaMate-Ladevorgang
  als Orphans angelegt.

  Die History wird via `Fetcher.collect/4` seitenweise geholt; bei begrenztem
  `range` dient der Range-Cutoff als `stop_before`-Watermark (frueher Abbruch),
  bei `range: :all` wird vollstaendig geblaettert (`stop_before == nil`).

  `run/2` gibt `{:ok, %{matched: m, orphans: o, created: c}}` zurueck. `matched`
  zaehlt nur neu bekostete Ladungen. Das PubSub-Topic (`topic/0`) ist fuer die
  LiveView gedacht, die Ergebnisse broadcastet.
  """

  import Ecto.Query
  alias TeslaMate.{Repo, Log}
  alias TeslaMate.Log.{Car, ChargingProcess}
  alias TeslaMate.ChargeCost.{Matcher, Fee, Orphan, Fetcher}

  @default_page_size 10

  @topic "charge_cost_backfill"
  def topic, do: @topic

  @doc """
  Optionen:
    * `:basis`           — `:gross | :net` (Pflicht)
    * `:range`           — `:all | :last_12_months | :last_30_days` (Default `:all`)
    * `:create_orphans?` — Bool (Default `false`)
    * `:page_size`       — Integer, Seitengroesse fuer die Pagination (Default #{@default_page_size})
    * `:fetch`           — `fun(vin, [page_no:, page_size:, sort_order:]) :: {:ok, [Session.t()]}`
                           (Default: echte Fleet-API via `Fetcher`)
    * `:now`             — `DateTime` (fuer Tests)
  """
  def run(%Car{} = car, opts) do
    basis = Keyword.fetch!(opts, :basis)
    create? = Keyword.get(opts, :create_orphans?, false)
    fetch = Keyword.get(opts, :fetch, &TeslaMate.Api.get_charging_history/2)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    since = range_cutoff(Keyword.get(opts, :range, :all), now)

    with {:ok, sessions} <- Fetcher.collect(fetch, car.vin, since, page_size: page_size) do
      processes = suc_processes(car, since)

      {matched, used_ids} =
        Enum.reduce(processes, {0, MapSet.new()}, fn cp, {n, used} ->
          case Matcher.match(cp, sessions) do
            nil ->
              {n, used}

            session ->
              n =
                if is_nil(cp.cost) do
                  {:ok, _} = Log.update_charging_process(cp, %{cost: Fee.total(session, basis)})
                  n + 1
                else
                  n
                end

              {n, MapSet.put(used, session.session_id)}
          end
        end)

      orphans = Enum.reject(sessions, &MapSet.member?(used_ids, &1.session_id))

      created =
        if create? do
          Enum.count(orphans, fn session -> Orphan.create(car, session, basis) == :ok end)
        else
          0
        end

      {:ok, %{matched: matched, orphans: length(orphans), created: created}}
    end
  end

  defp suc_processes(%Car{id: id}, nil) do
    from(cp in ChargingProcess, where: cp.car_id == ^id)
    |> suc()
    |> Repo.all()
  end

  defp suc_processes(%Car{id: id}, since) do
    from(cp in ChargingProcess, where: cp.car_id == ^id and cp.start_date >= ^since)
    |> suc()
    |> Repo.all()
  end

  defp suc(query) do
    where(
      query,
      [cp],
      fragment(
        "EXISTS (SELECT 1 FROM charges c WHERE c.charging_process_id = ? AND c.fast_charger_brand = 'Tesla')",
        cp.id
      )
    )
  end

  defp range_cutoff(:all, _now), do: nil
  defp range_cutoff(:last_12_months, now), do: DateTime.add(now, -365 * 24 * 3600, :second)
  defp range_cutoff(:last_30_days, now), do: DateTime.add(now, -30 * 24 * 3600, :second)
end
