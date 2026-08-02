defmodule TeslaApi.Charging do
  @moduledoc """
  Fleet-API: GET /api/1/dx/charging/history (von Tesla abgerechnete Lade-Sessions).

  TeslaMates Standard-Pipeline (TeslaApi) zeigt auf die Legacy-owner-api; dieser
  Endpoint ist Fleet-API, daher wird die volle Fleet-Host-URL explizit gesetzt
  (Default EU, via TESLA_FLEET_API_HOST ueberschreibbar). Der Token kommt aus
  dem bestehenden %TeslaApi.Auth{} (TokenAuth-Middleware setzt den Bearer-Header).

  KOSTEN: Tesla rechnet diesen Endpoint PRO DATENSATZ ab (~0,002 EUR/Record,
  ~333 Records Vollabruf ~ 0,67 EUR). Die serverseitigen Zeitfilter
  `startTime`/`endTime` werden vom Endpoint IGNORIERT (empirisch verifiziert
  2026-06-12: zukuenftige/vergangene Grenzwerte aendern das Ergebnis nicht). Kosten
  werden daher ausschliesslich ueber PAGINATION begrenzt: `sortOrder=desc` + kleine
  `pageSize`, und der Aufrufer (siehe `TeslaMate.ChargeCost.Fetcher`) blaettert nur
  so weit zurueck wie noetig. Die `:start_time`/`:end_time`-Optionen bleiben im Code
  (schaden nicht), bewirken serverseitig aber nichts.
  """
  alias TeslaApi.Auth
  alias TeslaMate.ChargeCost.Session

  @eu_host "https://fleet-api.prd.eu.vn.cloud.tesla.com"

  @doc """
  Holt die Charging-History fuer eine VIN.

  Optionen (alle optional, ungesetzte werden nicht an die API gesendet):
    * `:page_no`    — Integer (Pagination)
    * `:page_size`  — Integer (Pagination — der eigentliche Kosten-Hebel)
    * `:sort_by`    — String
    * `:sort_order` — String ("asc" | "desc")
    * `:start_time` — ISO8601-String; WIRD SERVERSEITIG IGNORIERT (s. moduledoc)
    * `:end_time`   — ISO8601-String; WIRD SERVERSEITIG IGNORIERT (s. moduledoc)
  """
  @spec history(Auth.t(), String.t(), keyword()) :: {:ok, [Session.t()]} | {:error, term()}
  def history(%Auth{} = auth, vin, opts \\ []) do
    url = fleet_host() <> "/api/1/dx/charging/history"
    query = build_query(vin, opts)

    case TeslaApi.get(url, query: query, opts: [access_token: auth.token]) do
      {:ok, %Tesla.Env{status: 200, body: body}} -> {:ok, parse(body)}
      {:ok, %Tesla.Env{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_query(vin, opts) do
    [
      vin: vin,
      startTime: opts[:start_time],
      endTime: opts[:end_time],
      pageNo: opts[:page_no],
      pageSize: opts[:page_size],
      sortBy: opts[:sort_by],
      sortOrder: opts[:sort_order]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp fleet_host, do: System.get_env("TESLA_FLEET_API_HOST", @eu_host)

  @spec parse(map() | list()) :: [Session.t()]
  def parse(body) do
    body
    |> results()
    |> Enum.map(&to_session/1)
  end

  defp results(%{"data" => %{"results" => r}}) when is_list(r), do: r
  defp results(%{"data" => r}) when is_list(r), do: r
  defp results(%{"results" => r}) when is_list(r), do: r
  defp results(%{"response" => r}) when is_list(r), do: r
  defp results(r) when is_list(r), do: r
  defp results(_), do: []

  defp to_session(r) do
    %Session{
      session_id: r["sessionId"],
      vin: r["vin"],
      site: r["siteLocationName"],
      start_date: parse_dt(r["chargeStartDateTime"]),
      end_date: parse_dt(r["chargeStopDateTime"]),
      energy_kwh: charging_kwh(r["fees"]),
      fees: Enum.map(r["fees"] || [], &to_fee/1)
    }
  end

  defp to_fee(f) do
    %{type: f["feeType"], total_due: dec(f["totalDue"]), net_due: dec(f["netDue"])}
  end

  defp charging_kwh(fees) do
    case Enum.find(fees || [], fn f -> f["feeType"] == "CHARGING" end) do
      %{"usageBase" => u} -> dec(u)
      _ -> nil
    end
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp dec(nil), do: nil
  defp dec(n) when is_integer(n), do: Decimal.new(n)
  defp dec(n) when is_float(n), do: Decimal.from_float(n)
  defp dec(s) when is_binary(s), do: Decimal.new(s)
end
