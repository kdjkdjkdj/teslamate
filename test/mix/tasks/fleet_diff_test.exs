defmodule Mix.Tasks.Fleet.DiffTest do
  use TeslaMate.DataCase, async: true

  alias TeslaMate.FleetTelemetry.{ShadowPosition, ShadowCharge}
  alias TeslaMate.Log.{Drive, Position, ChargingProcess, Charge}
  alias TeslaMate.Log

  setup do
    {:ok, car} = Log.create_car(%{eid: 1, vid: 1, vin: "TESTVIN0000000001", name: "T"})

    start = ~U[2026-06-23 10:00:00.000000Z]
    stop = ~U[2026-06-23 10:30:00.000000Z]

    {:ok, drive} =
      %Drive{car_id: car.id} |> Drive.changeset(%{start_date: start, end_date: stop}) |> Repo.insert()

    %{car: car, drive: drive, start: start, stop: stop}
  end

  test "zaehlt Punkte, groesste Luecke und Power-Stichproben", %{car: car, drive: drive, start: start} do
    for {min, pw} <- [{0, 10}, {10, 12}] do
      %Position{drive_id: drive.id}
      |> Position.changeset(%{
        car_id: car.id,
        date: DateTime.add(start, min * 60, :second),
        latitude: 48.0, longitude: 10.0, power: pw
      })
      |> Repo.insert!()
    end

    for {min, pw} <- [{0, 11}, {1, 11}, {9, 13}] do
      %ShadowPosition{}
      |> ShadowPosition.changeset(%{
        car_id: car.id, date: DateTime.add(start, min * 60, :second),
        latitude: 48.0, longitude: 10.0, power: pw, power_source: "packvi_proxy"
      })
      |> Repo.insert!()
    end

    report = Mix.Tasks.Fleet.Diff.report(drive_id: drive.id)

    assert report.shadow_count == 3
    assert report.poll_count == 2
    assert report.max_shadow_gap_s == 8 * 60
    assert is_map(report.field_coverage)
    assert report.field_coverage.power == 100.0
    assert length(report.power_samples) == 3
    # erster Schatten (min 0, power 11) -> naechster Poll (min 0, power 10)
    assert {11, 10} in report.power_samples
  end

  test "charging: Punkte, Kanten, charge_source und Power-Stichproben", %{car: car, start: start} do
    stop = DateTime.add(start, 30 * 60, :second)

    {:ok, pos} =
      %Position{}
      |> Position.changeset(%{car_id: car.id, date: start, latitude: 48.0, longitude: 10.0})
      |> Repo.insert()

    {:ok, cp} =
      %ChargingProcess{car_id: car.id, position_id: pos.id}
      |> ChargingProcess.changeset(%{start_date: start, end_date: stop})
      |> Repo.insert()

    for {min, pw} <- [{0, 60}, {10, 65}] do
      %Charge{charging_process_id: cp.id}
      |> Charge.changeset(%{
        date: DateTime.add(start, min * 60, :second),
        charge_energy_added: 1.0 * min,
        charger_power: pw,
        ideal_battery_range_km: 300.0
      })
      |> Repo.insert!()
    end

    for {min, pw, st} <- [
          {0, 61, "DetailedChargeStateStarting"},
          {1, 62, "DetailedChargeStateCharging"},
          {9, 64, "DetailedChargeStateComplete"}
        ] do
      %ShadowCharge{}
      |> ShadowCharge.changeset(%{
        car_id: car.id,
        date: DateTime.add(start, min * 60, :second),
        charging_state: st,
        charge_source: "dc",
        charger_power: pw
      })
      |> Repo.insert!()
    end

    report = Mix.Tasks.Fleet.Diff.report(charging_process_id: cp.id)

    assert report.shadow_count == 3
    assert report.poll_count == 2
    assert report.max_shadow_gap_s == 8 * 60
    assert report.charge_sources == ["dc"]

    assert report.state_edges == [
             "DetailedChargeStateStarting",
             "DetailedChargeStateCharging",
             "DetailedChargeStateComplete"
           ]

    assert report.field_coverage.charger_power == 100.0
    assert length(report.power_samples) == 3
    assert {61, 60} in report.power_samples
  end
end
