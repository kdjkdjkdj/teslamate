defmodule TeslaMate.FleetTelemetry.FieldStateTest do
  use ExUnit.Case, async: true
  alias TeslaMate.FleetTelemetry.FieldState

  test "put speichert Wert + Empfangszeit, get liest zurueck" do
    now = ~U[2026-06-25 10:00:00Z]
    fs = FieldState.new() |> FieldState.put("BatteryLevel", 64.0, now)
    assert FieldState.get(fs, "BatteryLevel") == 64.0
    assert FieldState.get(fs, "Unbekannt") == nil
  end

  test "present_count zaehlt nur non-nil Felder" do
    now = ~U[2026-06-25 10:00:00Z]
    fs =
      FieldState.new()
      |> FieldState.put("A", 1, now)
      |> FieldState.put("B", nil, now)
    assert FieldState.present_count(fs) == 1
  end

  test "max_age_s ist Alter des aeltesten Felds" do
    fs =
      FieldState.new()
      |> FieldState.put("A", 1, ~U[2026-06-25 10:00:00Z])
      |> FieldState.put("B", 2, ~U[2026-06-25 10:00:20Z])
    assert FieldState.max_age_s(fs, ~U[2026-06-25 10:00:30Z]) == 30
  end

  test "trigger? erkennt das konfigurierte Trigger-Feld" do
    fs = FieldState.new(trigger_field: "Location")
    assert FieldState.trigger?(fs, "Location")
    refute FieldState.trigger?(fs, "VehicleSpeed")
  end
end
