defmodule TeslaMate.ChargeCost.OrphanTest do
  use TeslaMate.DataCase

  alias TeslaMate.ChargeCost.{Orphan, Session}
  alias TeslaMate.Locations.Address
  alias TeslaMate.Log
  alias TeslaMate.Log.ChargingProcess
  alias TeslaMate.Repo

  defp car_fixture, do: car_fixture(%{})

  defp car_fixture(attrs) do
    id = :erlang.unique_integer([:positive]) |> rem(100_000)
    {:ok, car} =
      attrs
      |> Enum.into(%{eid: id, vid: id, vin: "ORPH#{id}", model: "MY"})
      |> Log.create_car()
    car
  end

  defp session(vin, attrs) do
    %Session{
      session_id: "S#{System.unique_integer([:positive])}",
      vin: vin,
      site: Map.get(attrs, :site, "Augsburg"),
      start_date: Map.fetch!(attrs, :start_date),
      end_date: Map.fetch!(attrs, :end_date),
      energy_kwh: Map.get(attrs, :energy_kwh),
      fees: Map.get(attrs, :fees, [])
    }
  end

  test "legt einen charging_process aus einer Session an" do
    car = car_fixture()
    s = session(car.vin, %{
      start_date: ~U[2026-03-01 10:00:00Z],
      end_date: ~U[2026-03-01 10:20:00Z],
      energy_kwh: Decimal.new("8.0"),
      fees: [%{type: "CHARGING", total_due: Decimal.new("3.50"), net_due: Decimal.new("2.94")}]
    })

    assert :ok = Orphan.create(car, s, :gross)

    [cp] = Repo.all(ChargingProcess)
    assert cp.car_id == car.id
    assert Decimal.equal?(cp.cost, Decimal.new("3.50"))
    assert Decimal.equal?(cp.charge_energy_added, Decimal.new("8.0"))
    assert DateTime.compare(cp.start_date, ~U[2026-03-01 10:00:00Z]) == :eq
    assert cp.duration_min == 20
    refute is_nil(cp.position_id)
  end

  test "verwendet net basis" do
    car = car_fixture()
    s = session(car.vin, %{
      start_date: ~U[2026-03-01 10:00:00Z],
      end_date: ~U[2026-03-01 10:20:00Z],
      energy_kwh: Decimal.new("8.0"),
      fees: [%{type: "CHARGING", total_due: Decimal.new("3.50"), net_due: Decimal.new("2.94")}]
    })

    assert :ok = Orphan.create(car, s, :net)
    [cp] = Repo.all(ChargingProcess)
    assert Decimal.equal?(cp.cost, Decimal.new("2.94"))
  end

  test "setzt den SuC-Standortnamen als Adresse (kein Unknown-Geocoding)" do
    car = car_fixture()
    s = session(car.vin, %{
      site: "Augsburg",
      start_date: ~U[2026-03-01 10:00:00Z],
      end_date: ~U[2026-03-01 10:20:00Z],
      energy_kwh: Decimal.new("8.0"),
      fees: [%{type: "CHARGING", total_due: Decimal.new("3.50"), net_due: Decimal.new("2.94")}]
    })

    assert :ok = Orphan.create(car, s, :gross)

    [cp] = Repo.all(ChargingProcess)
    refute is_nil(cp.address_id)
    addr = Repo.get!(Address, cp.address_id)
    assert addr.name == "Augsburg"
    assert addr.display_name == "Augsburg"
  end

  test "teilt sich eine Adresse fuer denselben Standort" do
    car = car_fixture()

    s1 = session(car.vin, %{
      site: "Augsburg",
      start_date: ~U[2026-03-01 10:00:00Z],
      end_date: ~U[2026-03-01 10:20:00Z]
    })

    s2 = session(car.vin, %{
      site: "Augsburg",
      start_date: ~U[2026-03-05 10:00:00Z],
      end_date: ~U[2026-03-05 10:20:00Z]
    })

    assert :ok = Orphan.create(car, s1, :gross)
    assert :ok = Orphan.create(car, s2, :gross)

    cps = Repo.all(ChargingProcess)
    assert length(cps) == 2
    assert cps |> Enum.map(& &1.address_id) |> Enum.uniq() |> length() == 1
    assert length(Repo.all(Address)) == 1
  end

  test "ohne Standortnamen kein Adress-Eintrag" do
    car = car_fixture()
    s = session(car.vin, %{
      site: nil,
      start_date: ~U[2026-03-01 10:00:00Z],
      end_date: ~U[2026-03-01 10:20:00Z]
    })

    assert :ok = Orphan.create(car, s, :gross)
    [cp] = Repo.all(ChargingProcess)
    assert is_nil(cp.address_id)
  end
end
