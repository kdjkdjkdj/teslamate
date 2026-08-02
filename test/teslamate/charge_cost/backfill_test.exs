defmodule TeslaMate.ChargeCost.BackfillTest do
  use TeslaMate.DataCase

  alias TeslaMate.ChargeCost.{Backfill, Session}
  alias TeslaMate.Log
  alias TeslaMate.Log.ChargingProcess
  alias TeslaMate.Repo

  defp car_fixture, do: car_fixture(%{})

  defp car_fixture(attrs) do
    id = :erlang.unique_integer([:positive]) |> rem(100_000)
    {:ok, car} =
      attrs
      |> Enum.into(%{eid: id, vid: id, vin: "BF#{id}", model: "MY"})
      |> Log.create_car()
    car
  end

  defp suc_process(car, attrs) do
    start = Map.fetch!(attrs, :start_date)
    {:ok, cp} =
      %ChargingProcess{car_id: car.id}
      |> ChargingProcess.changeset(%{
        start_date: start,
        position: %{car_id: car.id, date: start, latitude: 0.0, longitude: 0.0}
      })
      |> Repo.insert()

    {:ok, _} = Log.insert_charge(cp, %{
      date: start,
      charger_power: 150,
      fast_charger_brand: "Tesla",
      charge_energy_added: Map.get(attrs, :charge_energy_added, Decimal.new("10.0")),
      ideal_battery_range_km: Decimal.new("400.0")
    })

    Repo.get!(ChargingProcess, cp.id)
  end

  defp session(vin, id, start_dt, total_due) do
    %Session{
      session_id: id,
      vin: vin,
      start_date: start_dt,
      end_date: DateTime.add(start_dt, 1200, :second),
      energy_kwh: Decimal.new("10.0"),
      fees: [%{type: "CHARGING", total_due: Decimal.new(total_due), net_due: Decimal.new("2.52")}]
    }
  end

  test "matcht ueber Zeitraum, ignoriert Orphans wenn create_orphans? false" do
    car = car_fixture()
    cp = suc_process(car, %{start_date: ~U[2026-01-10 10:00:00Z]})

    sessions = [
      session(car.vin, "matched", ~U[2026-01-10 10:00:30Z], "3.00"),
      session(car.vin, "orphan", ~U[2026-02-01 12:00:00Z], "2.00")
    ]

    assert {:ok, %{matched: 1, orphans: 1, created: 0}} =
             Backfill.run(car,
               range: :all,
               create_orphans?: false,
               basis: :gross,
               fetch: fn _, _ -> {:ok, sessions} end
             )

    assert Decimal.equal?(Repo.get!(ChargingProcess, cp.id).cost, Decimal.new("3.00"))
    assert length(Repo.all(ChargingProcess)) == 1
  end

  test "legt Orphans an wenn create_orphans? true" do
    car = car_fixture()
    _cp = suc_process(car, %{start_date: ~U[2026-01-10 10:00:00Z]})

    sessions = [
      session(car.vin, "matched", ~U[2026-01-10 10:00:30Z], "3.00"),
      session(car.vin, "orphan", ~U[2026-02-01 12:00:00Z], "2.00")
    ]

    assert {:ok, %{matched: 1, orphans: 1, created: 1}} =
             Backfill.run(car,
               range: :all,
               create_orphans?: true,
               basis: :gross,
               fetch: fn _, _ -> {:ok, sessions} end
             )

    assert length(Repo.all(ChargingProcess)) == 2
  end

  test "range last_30_days schliesst alte Ladungen aus" do
    car = car_fixture()
    cp = suc_process(car, %{start_date: ~U[2026-01-01 10:00:00Z]})

    sessions = [session(car.vin, "old", ~U[2026-01-01 10:00:30Z], "3.00")]

    assert {:ok, %{matched: 0, orphans: 1, created: 0}} =
             Backfill.run(car,
               range: :last_30_days,
               basis: :gross,
               now: ~U[2026-06-12 00:00:00Z],
               fetch: fn _, _ -> {:ok, sessions} end
             )

    assert is_nil(Repo.get!(ChargingProcess, cp.id).cost)
  end

  test "dupliziert keine bereits bekostete Ladung als Orphan" do
    car = car_fixture()
    cp = suc_process(car, %{start_date: ~U[2026-01-10 10:00:00Z]})
    {:ok, _} = Log.update_charging_process(cp, %{cost: Decimal.new("3.00")})

    sessions = [session(car.vin, "already", ~U[2026-01-10 10:00:30Z], "3.00")]

    assert {:ok, %{matched: 0, orphans: 0, created: 0}} =
             Backfill.run(car,
               range: :all,
               create_orphans?: true,
               basis: :gross,
               fetch: fn _, _ -> {:ok, sessions} end
             )

    assert length(Repo.all(ChargingProcess)) == 1
    assert Decimal.equal?(Repo.get!(ChargingProcess, cp.id).cost, Decimal.new("3.00"))
  end
end
