defmodule TeslaMate.ChargeCost.MatcherTest do
  use ExUnit.Case, async: true
  alias TeslaMate.ChargeCost.{Matcher, Session}

  defp sess(id, start, stop, kwh) do
    %Session{session_id: id, vin: "V1", start_date: start, end_date: stop,
             energy_kwh: kwh && Decimal.new(kwh)}
  end

  defp cp(start, stop, kwh) do
    %{start_date: start, end_date: stop, charge_energy_added: kwh && Decimal.new(kwh)}
  end

  test "matcht Session mit ueberlappendem Zeitfenster" do
    sessions = [sess("a", ~U[2026-06-10 09:00:00Z], ~U[2026-06-10 09:20:00Z], nil),
                sess("b", ~U[2026-06-10 10:00:00Z], ~U[2026-06-10 10:25:00Z], nil)]
    process = cp(~U[2026-06-10 10:01:00Z], ~U[2026-06-10 10:24:00Z], nil)
    assert %Session{session_id: "b"} = Matcher.match(process, sessions)
  end

  test "akzeptiert Start innerhalb Toleranz (Default 600s)" do
    sessions = [sess("b", ~U[2026-06-10 10:00:00Z], ~U[2026-06-10 10:25:00Z], nil)]
    process = cp(~U[2026-06-10 10:08:00Z], ~U[2026-06-10 10:33:00Z], nil)
    assert %Session{session_id: "b"} = Matcher.match(process, sessions)
  end

  test "kein Match ausserhalb Toleranz" do
    sessions = [sess("b", ~U[2026-06-10 10:00:00Z], ~U[2026-06-10 10:25:00Z], nil)]
    process = cp(~U[2026-06-10 12:00:00Z], ~U[2026-06-10 12:25:00Z], nil)
    assert Matcher.match(process, sessions) == nil
  end

  test "Tie-Break ueber kWh-Naehe bei mehreren Kandidaten" do
    sessions = [sess("near", ~U[2026-06-10 10:00:00Z], ~U[2026-06-10 10:25:00Z], "30.0"),
                sess("far",  ~U[2026-06-10 10:00:30Z], ~U[2026-06-10 10:24:30Z], "10.0")]
    process = cp(~U[2026-06-10 10:00:10Z], ~U[2026-06-10 10:24:50Z], "31.0")
    assert %Session{session_id: "near"} = Matcher.match(process, sessions)
  end
end
