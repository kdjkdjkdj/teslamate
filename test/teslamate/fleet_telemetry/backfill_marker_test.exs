defmodule TeslaMate.FleetTelemetry.BackfillMarkerTest do
  use TeslaMate.DataCase, async: true

  alias TeslaMate.FleetTelemetry.BackfillMarker

  test "changeset akzeptiert vollstaendige Attrs" do
    cs =
      BackfillMarker.changeset(%BackfillMarker{}, %{
        car_id: 1,
        session_start: ~U[2026-07-12 09:45:19Z],
        session_end: ~U[2026-07-12 12:19:13Z],
        charging_process_id: 375
      })

    assert cs.valid?
  end

  test "changeset verlangt car_id + session_start + session_end" do
    refute BackfillMarker.changeset(%BackfillMarker{}, %{}).valid?
  end
end
