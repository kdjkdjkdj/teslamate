defmodule TeslaMate.ChargeCost.Fee do
  @moduledoc "Summiert die Fees einer Session zum Gesamtbetrag (brutto/netto)."
  alias TeslaMate.ChargeCost.Session

  @spec total(Session.t(), :gross | :net) :: Decimal.t()
  def total(%Session{fees: fees}, basis) when basis in [:gross, :net] do
    key = if basis == :gross, do: :total_due, else: :net_due

    Enum.reduce(fees, Decimal.new(0), fn fee, acc ->
      Decimal.add(acc, Map.get(fee, key) || Decimal.new(0))
    end)
  end
end
