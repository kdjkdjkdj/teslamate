defmodule TeslaMate.ChargeCost.FetcherTest do
  use ExUnit.Case, async: true

  alias TeslaMate.ChargeCost.{Fetcher, Session}

  defp sess(id, start_dt) do
    %Session{session_id: id, vin: "V", start_date: start_dt, end_date: start_dt, fees: []}
  end

  # Fetch-Fun, die `pages` (Liste von Session-Listen) seitenweise nach page_no liefert.
  defp paged_fetch(pages) do
    fn _vin, opts ->
      page_no = Keyword.fetch!(opts, :page_no)
      {:ok, Enum.at(pages, page_no - 1, [])}
    end
  end

  test "akkumuliert ueber mehrere Seiten bis zur kurzen (letzten) Seite" do
    pages = [
      [sess(1, ~U[2026-06-10 00:00:00Z]), sess(2, ~U[2026-06-09 00:00:00Z])],
      [sess(3, ~U[2026-06-08 00:00:00Z])]
    ]

    assert {:ok, got} = Fetcher.collect(paged_fetch(pages), "V", nil, page_size: 2)
    assert Enum.map(got, & &1.session_id) == [1, 2, 3]
  end

  test "stoppt am Watermark (stop_before)" do
    pages = [
      [sess(1, ~U[2026-06-10 00:00:00Z]), sess(2, ~U[2026-06-09 00:00:00Z])],
      [sess(3, ~U[2026-06-01 00:00:00Z]), sess(4, ~U[2026-05-30 00:00:00Z])],
      [sess(5, ~U[2026-05-01 00:00:00Z]), sess(6, ~U[2026-04-01 00:00:00Z])]
    ]

    # stop_before = 2026-06-05: Seite 2 enthaelt aelteste 2026-05-30 < stop_before -> stop nach Seite 2.
    assert {:ok, got} =
             Fetcher.collect(paged_fetch(pages), "V", ~U[2026-06-05 00:00:00Z], page_size: 2)

    assert Enum.map(got, & &1.session_id) == [1, 2, 3, 4]
  end

  test "Vollabruf (stop_before nil) blaettert bis zur kurzen Seite" do
    pages = [
      [sess(1, ~U[2026-06-10 00:00:00Z]), sess(2, ~U[2026-06-09 00:00:00Z])],
      [sess(3, ~U[2026-06-08 00:00:00Z]), sess(4, ~U[2026-06-07 00:00:00Z])],
      [sess(5, ~U[2026-06-06 00:00:00Z])]
    ]

    assert {:ok, got} = Fetcher.collect(paged_fetch(pages), "V", nil, page_size: 2)
    assert length(got) == 5
  end

  test "max_pages-Cap verhindert Endlosblaettern" do
    # Jede Seite voll (page_size 2), nie kuerzer, stop_before nil -> Cap (50 Seiten) greift.
    fetch = fn _vin, opts ->
      n = Keyword.fetch!(opts, :page_no)
      {:ok, [sess(2 * n - 1, ~U[2026-06-10 00:00:00Z]), sess(2 * n, ~U[2026-06-10 00:00:00Z])]}
    end

    assert {:ok, got} = Fetcher.collect(fetch, "V", nil, page_size: 2)
    assert length(got) == 50 * 2
  end

  test "Fehler wird durchgereicht" do
    fetch = fn _vin, _opts -> {:error, :boom} end
    assert {:error, :boom} = Fetcher.collect(fetch, "V", nil, page_size: 2)
  end
end
