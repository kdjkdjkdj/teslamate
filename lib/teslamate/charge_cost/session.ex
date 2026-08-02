defmodule TeslaMate.ChargeCost.Session do
  @moduledoc "Eine von Tesla abgerechnete Lade-Session aus dx/charging/history."

  @type fee :: %{type: String.t(), total_due: Decimal.t(), net_due: Decimal.t()}
  @type t :: %__MODULE__{
          session_id: String.t(),
          vin: String.t(),
          site: String.t() | nil,
          start_date: DateTime.t(),
          end_date: DateTime.t(),
          energy_kwh: Decimal.t() | nil,
          fees: [fee()]
        }

  @enforce_keys [:session_id, :vin, :start_date, :end_date]
  defstruct [:session_id, :vin, :site, :start_date, :end_date, :energy_kwh, fees: []]
end
