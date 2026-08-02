defmodule TeslaMate.ChargeCost.Sync do
  @moduledoc """
  Leitet offene Supercharger-Ladungen ab (SuC + cost IS NULL + im Fenster),
  holt die Fleet-Charging-History per Pagination und schreibt `cost`.

  Stateless: jeder Lauf leitet die Arbeitsmenge frisch aus der DB ab. Da der
  Endpoint serverseitige Zeitfilter ignoriert und pro Datensatz abrechnet, wird
  via `Fetcher.collect/4` nur so weit zurueckgeblaettert, bis die aelteste offene
  Ladung (minus Marge) ueberschritten ist (`stop_before`-Watermark) -> minimale
  Fleet-API-Kosten.
  """

  import Ecto.Query
  require Logger

  alias TeslaMate.{Repo, Log}
  alias TeslaMate.Log.{Car, ChargingProcess}
  alias TeslaMate.ChargeCost.{Matcher, Fee, Fetcher}

  # Marge vor der aeltesten offenen Ladung, damit eine evtl. frueher startende
  # Tesla-Session sicher mit erfasst wird.
  @start_margin_s 3600
  @default_page_size 10

  @doc """
  Synchronisiert die Kosten offener SuC-Ladungen eines Autos.

  Optionen:
    * `:basis`       — `:gross | :net` (Pflicht)
    * `:window_days` — Integer, wie weit zurueck offene Ladungen gesucht werden (Pflicht)
    * `:page_size`   — Integer, Seitengroesse fuer die Pagination (Default #{@default_page_size})
    * `:fetch`       — `fun(vin, [page_no:, page_size:, sort_order:]) :: {:ok, [Session.t()]} | {:error, term}`
                       (Default: echte Fleet-API via `Fetcher`)
    * `:now`         — `DateTime` (fuer Tests; Default: `DateTime.utc_now/0`)

  Gibt `{:ok, %{open: n, matched: m}}` oder `{:error, reason}` zurueck.
  """
  def run(%Car{} = car, opts) do
    basis = Keyword.fetch!(opts, :basis)
    window = Keyword.fetch!(opts, :window_days)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    fetch = Keyword.get(opts, :fetch, &TeslaMate.Api.get_charging_history/2)

    open = open_processes(car, window, now)

    if open == [] do
      {:ok, %{open: 0, matched: 0}}
    else
      stop_before = stop_before(open)

      with {:ok, sessions} <- Fetcher.collect(fetch, car.vin, stop_before, page_size: page_size) do
        matched =
          Enum.reduce(open, 0, fn cp, acc ->
            case Matcher.match(cp, sessions) do
              nil ->
                acc

              session ->
                {:ok, _} = Log.update_charging_process(cp, %{cost: Fee.total(session, basis)})
                acc + 1
            end
          end)

        {:ok, %{open: length(open), matched: matched}}
      end
    end
  end

  # Watermark: aelteste offene Ladung minus Marge. Aelteres brauchen wir nicht.
  defp stop_before(open) do
    open
    |> Enum.map(& &1.start_date)
    |> Enum.min(DateTime)
    |> DateTime.add(-@start_margin_s, :second)
  end

  # SuC (charge mit fast_charger_brand = 'Tesla') + cost IS NULL + start_date im Fenster
  defp open_processes(%Car{id: car_id}, window_days, now) do
    cutoff = DateTime.add(now, -window_days * 24 * 3600, :second)

    from(cp in ChargingProcess,
      where: cp.car_id == ^car_id and is_nil(cp.cost) and cp.start_date >= ^cutoff,
      where:
        fragment(
          "EXISTS (SELECT 1 FROM charges c WHERE c.charging_process_id = ? AND c.fast_charger_brand = 'Tesla')",
          cp.id
        )
    )
    |> Repo.all()
  end
end
