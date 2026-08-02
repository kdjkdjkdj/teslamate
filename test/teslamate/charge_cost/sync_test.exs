defmodule TeslaMate.ChargeCost.SyncTest do
  use TeslaMate.DataCase

  # Fester Bezugszeitpunkt: die Fixtures liegen auf 2026-06-10, das Suchfenster
  # (window_days) rechnet gegen `now`. Ohne festes `now` fallen die Fixtures mit
  # fortschreitender Realzeit aus dem Fenster - die Tests wurden dadurch ab dem
  # 24.06.2026 rot bzw. falsch-gruen.
  @now ~U[2026-06-12 00:00:00Z]

  alias TeslaMate.Log
  alias TeslaMate.Log.{ChargingProcess}
  alias TeslaMate.ChargeCost.{Sync, Session}
  alias TeslaMate.Repo

  defp car_fixture(attrs \\ %{}) do
    id = :erlang.unique_integer([:positive]) |> rem(100_000)
    {:ok, car} =
      attrs
      |> Enum.into(%{eid: id, vid: id, vin: "SYNC#{id}", model: "MY"})
      |> Log.create_car()
    car
  end

  defp suc_process(car, attrs \\ %{}) do
    start = Map.get(attrs, :start_date, ~U[2026-06-10 10:00:00Z])
    defaults = %{
      start_date: start,
      position: %{car_id: car.id, date: start, latitude: 0.0, longitude: 0.0}
    }
    {:ok, cp} =
      %ChargingProcess{car_id: car.id}
      |> ChargingProcess.changeset(Map.merge(defaults, attrs))
      |> Repo.insert()

    charge_date = Map.get(attrs, :start_date, ~U[2026-06-10 10:01:00Z])
    kwh = Map.get(attrs, :charge_energy_added, Decimal.new("10.0"))

    {:ok, _} = Log.insert_charge(cp, %{
      date: charge_date,
      charger_power: 150,
      fast_charger_brand: "Tesla",
      charge_energy_added: kwh,
      ideal_battery_range_km: Decimal.new("400.0")
    })

    Repo.get!(ChargingProcess, cp.id)
  end

  defp session(vin, start_dt, kwh_str, total_due_str) do
    %Session{
      session_id: "S#{System.unique_integer([:positive])}",
      vin: vin,
      start_date: start_dt,
      end_date: DateTime.add(start_dt, 1500, :second),
      energy_kwh: Decimal.new(kwh_str),
      fees: [%{type: "CHARGING", total_due: Decimal.new(total_due_str), net_due: Decimal.new("4.15")}]
    }
  end

  test "schreibt cost fuer gematchte SuC-Ladung ohne Kosten" do
    car = car_fixture()
    cp = suc_process(car, %{start_date: ~U[2026-06-10 10:00:00Z], charge_energy_added: Decimal.new("10.0")})
    sessions = [session(car.vin, ~U[2026-06-10 10:00:30Z], "10.0", "4.94")]
    fake_fetch = fn _vin, _opts -> {:ok, sessions} end

    assert {:ok, %{open: 1, matched: 1}} =
             Sync.run(car, basis: :gross, window_days: 14, fetch: fake_fetch, now: @now)

    updated = Repo.get!(ChargingProcess, cp.id)
    assert Decimal.equal?(updated.cost, Decimal.new("4.94"))
  end

  test "laesst manuell gesetzte Kosten unberuehrt" do
    car = car_fixture()
    cp = suc_process(car, %{start_date: ~U[2026-06-10 10:00:00Z], charge_energy_added: Decimal.new("10.0")})
    {:ok, _} = Log.update_charging_process(cp, %{cost: Decimal.new("9.99")})

    sessions = [session(car.vin, ~U[2026-06-10 10:00:30Z], "10.0", "4.94")]
    fake_fetch = fn _vin, _opts -> {:ok, sessions} end

    assert {:ok, %{open: 0, matched: 0}} =
             Sync.run(car, basis: :gross, window_days: 14, fetch: fake_fetch, now: @now)

    updated = Repo.get!(ChargingProcess, cp.id)
    assert Decimal.equal?(updated.cost, Decimal.new("9.99"))
  end

  test "ignoriert Ladungen ausserhalb des Fensters" do
    car = car_fixture()
    _cp = suc_process(car, %{start_date: ~U[2025-01-01 10:00:00Z]})
    fake_fetch = fn _vin, _opts -> {:ok, []} end

    assert {:ok, %{open: 0, matched: 0}} =
             Sync.run(car, basis: :gross, window_days: 14, fetch: fake_fetch, now: @now)
  end

  test "kein Match wenn keine passende Session" do
    car = car_fixture()
    cp = suc_process(car)
    fake_fetch = fn _vin, _opts -> {:ok, []} end

    assert {:ok, %{open: 1, matched: 0}} =
             Sync.run(car, basis: :gross, window_days: 14, fetch: fake_fetch, now: @now)

    updated = Repo.get!(ChargingProcess, cp.id)
    assert is_nil(updated.cost)
  end

  test "verwendet net basis wenn konfiguriert" do
    car = car_fixture()
    cp = suc_process(car, %{start_date: ~U[2026-06-10 10:00:00Z], charge_energy_added: Decimal.new("10.0")})
    sessions = [session(car.vin, ~U[2026-06-10 10:00:30Z], "10.0", "4.94")]
    fake_fetch = fn _vin, _opts -> {:ok, sessions} end

    assert {:ok, %{open: 1, matched: 1}} =
             Sync.run(car, basis: :net, window_days: 14, fetch: fake_fetch, now: @now)

    updated = Repo.get!(ChargingProcess, cp.id)
    assert Decimal.equal?(updated.cost, Decimal.new("4.15"))
  end
end
