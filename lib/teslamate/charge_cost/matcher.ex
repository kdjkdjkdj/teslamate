defmodule TeslaMate.ChargeCost.Matcher do
  @moduledoc """
  Findet zu einem charging_process die passende Tesla-Lade-Session.
  Kriterium: Startzeit innerhalb Toleranz; bei mehreren Kandidaten gewinnt
  die geringste kombinierte Zeit-+kWh-Distanz.
  """
  alias TeslaMate.ChargeCost.Session

  @default_tolerance_s 600

  @spec match(map(), [Session.t()]) :: Session.t() | nil
  def match(charging_process, sessions), do: match(charging_process, sessions, [])

  @spec match(map(), [Session.t()], keyword()) :: Session.t() | nil
  def match(charging_process, sessions, opts) do
    tol = Keyword.get(opts, :tolerance_s, @default_tolerance_s)

    sessions
    |> Enum.filter(fn s -> within_tolerance?(s, charging_process, tol) end)
    |> case do
      [] -> nil
      candidates -> Enum.min_by(candidates, fn s -> distance(s, charging_process) end)
    end
  end

  defp within_tolerance?(%Session{start_date: s}, %{start_date: cs}, tol) do
    abs(DateTime.diff(s, cs, :second)) <= tol
  end

  defp distance(%Session{} = s, cp) do
    time = abs(DateTime.diff(s.start_date, cp.start_date, :second))
    kwh = kwh_distance(s.energy_kwh, Map.get(cp, :charge_energy_added))
    time + kwh * 60
  end

  defp kwh_distance(%Decimal{} = a, %Decimal{} = b) do
    a |> Decimal.sub(b) |> Decimal.abs() |> Decimal.to_float()
  end

  defp kwh_distance(_, _), do: 0.0
end
