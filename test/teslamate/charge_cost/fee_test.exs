defmodule TeslaMate.ChargeCost.FeeTest do
  use ExUnit.Case, async: true
  alias TeslaMate.ChargeCost.{Fee, Session}

  defp session(fees) do
    %Session{
      session_id: "s1", vin: "V1",
      start_date: ~U[2026-06-10 10:00:00Z], end_date: ~U[2026-06-10 10:30:00Z],
      fees: fees
    }
  end

  test "summiert alle Fees brutto" do
    s = session([
      %{type: "CHARGING", total_due: Decimal.new("4.94"), net_due: Decimal.new("4.15")},
      %{type: "CONGESTION", total_due: Decimal.new("1.00"), net_due: Decimal.new("0.84")}
    ])
    assert Decimal.equal?(Fee.total(s, :gross), Decimal.new("5.94"))
  end

  test "summiert alle Fees netto" do
    s = session([
      %{type: "CHARGING", total_due: Decimal.new("4.94"), net_due: Decimal.new("4.15")}
    ])
    assert Decimal.equal?(Fee.total(s, :net), Decimal.new("4.15"))
  end

  test "leere Fees ergeben 0" do
    assert Decimal.equal?(Fee.total(session([]), :gross), Decimal.new(0))
  end
end
