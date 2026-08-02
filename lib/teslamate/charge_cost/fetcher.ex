defmodule TeslaMate.ChargeCost.Fetcher do
  @moduledoc """
  Blaettert die Fleet-Charging-History seitenweise (sortOrder=desc, neueste zuerst)
  und akkumuliert Sessions, bis ein Abbruchkriterium greift.

  Hintergrund: Der `dx/charging/history`-Endpoint IGNORIERT serverseitige Zeitfilter
  (`startTime`/`endTime`, empirisch verifiziert 2026-06-12) und rechnet pro Datensatz
  ab. Der Kostenhebel ist daher, moeglichst wenige Records zu ziehen — via kleiner
  Seitengroesse + fruehem Abbruch an einem aus dem DB-Zustand abgeleiteten Watermark
  (`stop_before`).

  `collect/4` stoppt, sobald:
    * die letzte Seite kuerzer als `page_size` ist (keine weiteren Daten), ODER
    * die aelteste Session der Seite vor `stop_before` liegt (nichts Neueres mehr), ODER
    * `@max_pages` erreicht ist (Sicherheitskappe).

  `stop_before == nil` -> Vollabruf (alle Seiten bis zur letzten).
  """

  alias TeslaMate.ChargeCost.Session

  @max_pages 50
  @default_page_size 10

  @typedoc """
  `fun(vin, [page_no: integer, page_size: integer, sort_order: String.t()])`
  -> `{:ok, [Session.t()]} | {:error, term}`
  """
  @type fetch_fun :: (String.t(), keyword() -> {:ok, [Session.t()]} | {:error, term()})

  @spec collect(fetch_fun(), String.t(), DateTime.t() | nil, keyword()) ::
          {:ok, [Session.t()]} | {:error, term()}
  def collect(fetch, vin, stop_before, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    do_collect(fetch, vin, stop_before, page_size, 1, [])
  end

  defp do_collect(_fetch, _vin, _stop_before, _page_size, page_no, acc)
       when page_no > @max_pages do
    {:ok, acc}
  end

  defp do_collect(fetch, vin, stop_before, page_size, page_no, acc) do
    case fetch.(vin, page_no: page_no, page_size: page_size, sort_order: "desc") do
      {:ok, sessions} ->
        acc = acc ++ sessions

        cond do
          length(sessions) < page_size -> {:ok, acc}
          reached_watermark?(sessions, stop_before) -> {:ok, acc}
          true -> do_collect(fetch, vin, stop_before, page_size, page_no + 1, acc)
        end

      {:error, _} = err ->
        err
    end
  end

  # true, wenn die aelteste Session der Seite vor stop_before liegt -> danach kommt
  # (sortOrder=desc) nur noch Aelteres, das wir nicht brauchen.
  defp reached_watermark?(_sessions, nil), do: false

  defp reached_watermark?(sessions, %DateTime{} = stop_before) do
    sessions
    |> Enum.map(& &1.start_date)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> false
      dates -> DateTime.compare(Enum.min(dates, DateTime), stop_before) == :lt
    end
  end
end
