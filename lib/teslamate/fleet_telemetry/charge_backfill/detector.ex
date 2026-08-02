defmodule TeslaMate.FleetTelemetry.ChargeBackfill.Detector do
  @moduledoc """
  Reine Erkennungslogik fuer den Charge-Backfill (keine DB, keine Seiteneffekte).
  Clustert Shadow-Ladezeilen in Sessions und entscheidet, welche davon
  nachgetragen werden sollen.
  """

  @gap_min 20
  @settle_min 15

  @doc """
  Clustert zeitlich sortierbare Shadow-Zeilen (Maps mit `:date`) in Sessions.
  Eine Luecke > `opts[:gap_min]` (Default #{@gap_min}) min trennt zwei Sessions.
  Die juengste Session wird nur zurueckgegeben, wenn sie seit
  `opts[:min_settle_min]` (Default #{@settle_min}) min abgeschlossen ist
  (`opts[:now]` Pflicht) -- verhindert das Anfassen einer evtl. noch laufenden Ladung.
  Rueckgabe: Liste von `%{rows: [...], start: DateTime, end: DateTime}`.
  """
  def cluster_sessions(rows, opts \\ [])
  def cluster_sessions([], _opts), do: []

  def cluster_sessions(rows, opts) do
    gap = Keyword.get(opts, :gap_min, @gap_min)
    settle = Keyword.get(opts, :min_settle_min, @settle_min)
    now = Keyword.fetch!(opts, :now)

    rows
    |> Enum.sort_by(& &1.date, DateTime)
    |> chunk_by_gap(gap * 60)
    |> Enum.map(fn chunk ->
      %{rows: chunk, start: hd(chunk).date, end: List.last(chunk).date}
    end)
    |> drop_unsettled(now, settle * 60)
  end

  @doc """
  True, wenn ein `charging_process` (`%{start_date, end_date}`) das Session-Fenster
  `[start, end]` schneidet. Ein offenes `end_date` (nil) zaehlt als "bis jetzt offen".
  Schuetzt real (per Poll) erfasste Ladungen vor doppeltem Nachtrag.
  """
  def overlaps?(%{start: s, end: e}, cprocs) do
    Enum.any?(cprocs, fn %{start_date: cs} = cp ->
      ce = Map.get(cp, :end_date) || DateTime.utc_now()
      DateTime.compare(cs, e) != :gt and DateTime.compare(ce, s) != :lt
    end)
  end

  @doc """
  True, wenn die Session gross genug ist, um nachgetragen zu werden:
  Energie (max-min `charge_energy_added`) >= `opts[:min_kwh]` (Default 1.0) UND
  Dauer >= `opts[:min_minutes]` (Default 5). Filtert Mess-Rauschen / Mini-Vorgaenge.
  """
  def significant?(session, opts \\ []) do
    min_kwh = Keyword.get(opts, :min_kwh, 1.0)
    min_min = Keyword.get(opts, :min_minutes, 5)
    energy = energy_kwh(session.rows)
    minutes = DateTime.diff(session.end, session.start) / 60
    energy >= min_kwh and minutes >= min_min
  end

  @doc """
  True, wenn die Session mindestens eine aktive Lade-Phase (`charging_state`
  enthaelt "Charging") hat. Reine Stopped-/Complete-Sessions sind keine Ladung
  (z.B. Auto nur geweckt -> pusht kumulative Zaehlerstaende) und werden nicht
  nachgetragen.
  """
  def charging_session?(session) do
    Enum.any?(session.rows, fn r ->
      state = Map.get(r, :charging_state) || ""
      String.contains?(state, "Charging")
    end)
  end

  defp energy_kwh(rows) do
    vals = rows |> Enum.map(&to_f(&1.charge_energy_added)) |> Enum.reject(&is_nil/1)

    case vals do
      [] -> 0.0
      _ -> Enum.max(vals) - Enum.min(vals)
    end
  end

  defp to_f(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_f(n) when is_number(n), do: n * 1.0
  defp to_f(_), do: nil

  defp chunk_by_gap(rows, gap_s) do
    Enum.chunk_while(
      rows,
      [],
      fn r, acc ->
        case acc do
          [] ->
            {:cont, [r]}

          [prev | _] ->
            if DateTime.diff(r.date, prev.date) > gap_s,
              do: {:cont, Enum.reverse(acc), [r]},
              else: {:cont, [r | acc]}
        end
      end,
      fn
        [] -> {:cont, []}
        acc -> {:cont, Enum.reverse(acc), []}
      end
    )
  end

  defp drop_unsettled(sessions, now, settle_s) do
    case List.last(sessions) do
      nil ->
        sessions

      last ->
        if DateTime.diff(now, last.end) <= settle_s,
          do: Enum.drop(sessions, -1),
          else: sessions
    end
  end
end
