defmodule TeslaMate.FleetTelemetry.ChargeBackfill.DetectorTest do
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.ChargeBackfill.Detector

  defp row(min), do: %{date: DateTime.add(~U[2026-07-12 09:45:00Z], min * 60, :second)}

  test "trennt Sessions an einer Luecke > 20 min" do
    rows = [row(0), row(5), row(50), row(55)]
    now = ~U[2026-07-12 13:00:00Z]
    sessions = Detector.cluster_sessions(rows, now: now)
    assert length(sessions) == 2
    assert hd(sessions).start == row(0).date
    assert List.last(sessions).end == row(55).date
  end

  test "unterdrueckt die juengste Session, wenn noch nicht abgekuehlt (< 15 min)" do
    rows = [row(0), row(5)]
    now = DateTime.add(row(5).date, 5 * 60, :second)
    assert Detector.cluster_sessions(rows, now: now) == []
  end

  test "leere Eingabe -> keine Sessions" do
    assert Detector.cluster_sessions([], now: ~U[2026-07-12 13:00:00Z]) == []
  end

  test "overlaps? erkennt einen schneidenden charging_process" do
    session = %{start: ~U[2026-07-12 09:45:00Z], end: ~U[2026-07-12 12:19:00Z]}

    assert Detector.overlaps?(session, [
             %{start_date: ~U[2026-07-12 11:00:00Z], end_date: ~U[2026-07-12 11:30:00Z]}
           ])

    refute Detector.overlaps?(session, [
             %{start_date: ~U[2026-07-12 13:00:00Z], end_date: ~U[2026-07-12 13:30:00Z]}
           ])

    # offenes end_date zaehlt als "bis jetzt offen"
    assert Detector.overlaps?(session, [%{start_date: ~U[2026-07-12 12:00:00Z], end_date: nil}])
  end

  test "significant? filtert Rausch (Energie + Dauer)" do
    long = %{
      start: ~U[2026-07-12 09:45:00Z],
      end: ~U[2026-07-12 12:19:00Z],
      rows: [
        %{charge_energy_added: Decimal.new("0.0")},
        %{charge_energy_added: Decimal.new("25.0")}
      ]
    }

    assert Detector.significant?(long)

    tiny = %{
      start: ~U[2026-07-12 09:45:00Z],
      end: ~U[2026-07-12 09:47:00Z],
      rows: [
        %{charge_energy_added: Decimal.new("0.0")},
        %{charge_energy_added: Decimal.new("0.3")}
      ]
    }

    refute Detector.significant?(tiny)
  end

  test "charging_session? verlangt mindestens eine aktive Lade-Phase" do
    charging = %{
      rows: [
        %{charging_state: "DetailedChargeStateStopped"},
        %{charging_state: "DetailedChargeStateCharging"},
        %{charging_state: "DetailedChargeStateStopped"}
      ]
    }

    assert Detector.charging_session?(charging)

    # reine Stopped-Session (Auto nur geweckt, kumulative Zaehlerstaende) -> keine Ladung
    stopped_only = %{
      rows: [
        %{charging_state: "DetailedChargeStateStopped"},
        %{charging_state: "DetailedChargeStateStopped"}
      ]
    }

    refute Detector.charging_session?(stopped_only)
  end
end
