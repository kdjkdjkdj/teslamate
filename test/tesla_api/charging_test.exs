defmodule TeslaApi.ChargingTest do
  use ExUnit.Case, async: true
  alias TeslaApi.Charging
  alias TeslaMate.ChargeCost.Fee

  @synthetic %{
    "data" => %{
      "totalResults" => 1,
      "results" => [
        %{
          "sessionId" => "S1",
          "vin" => "V1",
          "siteLocationName" => "Example City",
          "chargeStartDateTime" => "2026-06-10T10:00:00Z",
          "chargeStopDateTime" => "2026-06-10T10:25:00Z",
          "fees" => [
            %{"feeType" => "CHARGING", "usageBase" => 10.99, "totalDue" => 4.94, "netDue" => 4.15}
          ]
        }
      ]
    }
  }

  # Reale Fleet-API-Envelope-Form (data ist ein direktes Array) mit synthetischen Werten.
  @real %{
    "data" => [
      %{
        "sessionId" => 100_000_001,
        "vin" => "5YJ3E1EA7KF000000",
        "siteLocationName" => "Example City, Country - Site",
        "chargeStartDateTime" => "2024-01-15T12:44:19+02:00",
        "chargeStopDateTime" => "2024-01-15T12:58:38+02:00",
        "countryCode" => "DE",
        "fees" => [
          %{"feeType" => "CHARGING", "usageBase" => 12.3456, "totalDue" => 5.67, "netDue" => 4.32,
            "currencyCode" => "EUR"},
          %{"feeType" => "CONGESTION", "usageBase" => 0, "totalDue" => 0, "netDue" => 0,
            "currencyCode" => "EUR"}
        ],
        "invoices" => [%{"fileName" => "x.pdf", "contentId" => "abc", "invoiceType" => "IMMEDIATE"}]
      }
    ]
  }

  test "parst die synthetische data.results-Form" do
    assert [s] = Charging.parse(@synthetic)
    assert s.session_id == "S1"
    assert s.site == "Example City"
    assert s.start_date == ~U[2026-06-10 10:00:00Z]
    assert Decimal.equal?(s.energy_kwh, Decimal.new("10.99"))
    assert [%{type: "CHARGING", total_due: td, net_due: nd}] = s.fees
    assert Decimal.equal?(td, Decimal.new("4.94"))
    assert Decimal.equal?(nd, Decimal.new("4.15"))
  end

  test "parst echte Fleet-Envelope ({data: [...]}) inkl. Offset-Zeit und Congestion-Fee" do
    assert [s] = Charging.parse(@real)
    assert s.session_id == 100_000_001
    assert s.vin == "5YJ3E1EA7KF000000"
    assert s.site == "Example City, Country - Site"
    assert s.start_date == ~U[2024-01-15 10:44:19Z]
    assert Decimal.equal?(s.energy_kwh, Decimal.new("12.3456"))
    assert length(s.fees) == 2
    assert Decimal.equal?(Fee.total(s, :gross), Decimal.new("5.67"))
    assert Decimal.equal?(Fee.total(s, :net), Decimal.new("4.32"))
  end

  test "robust gegen leere/fehlende Ergebnisse" do
    assert Charging.parse(%{"data" => %{"results" => []}}) == []
    assert Charging.parse(%{"data" => []}) == []
    assert Charging.parse(%{}) == []
  end
end
