defmodule TeslaMate.FleetTelemetry.ChargeBackfill.ReconstructorTest do
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.ChargeBackfill.Reconstructor

  test "to_charge_attrs uebernimmt Energie roh (v2-Mapper ist bereits akkuseitig)" do
    row = %{
      date: ~U[2026-07-12 10:00:00Z],
      battery_level: 30,
      usable_battery_level: 30,
      charge_energy_added: Decimal.new("3.6"),
      charger_actual_current: 16,
      charger_phases: 2,
      charger_power: 11,
      charger_voltage: 224,
      ideal_battery_range_km: Decimal.new("150.0"),
      rated_battery_range_km: Decimal.new("150.0")
    }

    attrs = Reconstructor.to_charge_attrs(row)

    assert attrs.charge_energy_added == Decimal.new("3.6")
    assert attrs.charger_power == 11
    assert attrs.charger_phases == 2
    assert attrs.conn_charge_cable == "IEC"
    assert attrs.fast_charger_present == false
  end

  test "reconstruct legt cproc an, fuellt charges, ruft complete" do
    session = %{
      start: ~U[2026-07-12 09:45:00Z],
      end: ~U[2026-07-12 12:19:00Z],
      rows: [
        %{
          date: ~U[2026-07-12 09:45:00Z],
          battery_level: 27,
          usable_battery_level: 27,
          charge_energy_added: Decimal.new("0.0"),
          charger_actual_current: 16,
          charger_phases: 2,
          charger_power: 0,
          charger_voltage: nil,
          ideal_battery_range_km: Decimal.new("129.0"),
          rated_battery_range_km: Decimal.new("129.0")
        }
      ]
    }

    test_pid = self()

    fake_log = %{
      start_charging_process: fn _car, pos, _opts ->
        send(test_pid, {:start, pos})
        {:ok, %{id: 999}}
      end,
      insert_charge: fn cproc, attrs ->
        send(test_pid, {:charge, cproc.id, attrs})
        {:ok, attrs}
      end,
      complete_charging_process: fn cproc ->
        send(test_pid, {:complete, cproc.id})
        {:ok, cproc}
      end
    }

    pos = %{latitude: 48.87, longitude: 9.34, battery_level: 27}

    assert {:ok, %{id: 999}} =
             Reconstructor.reconstruct(%{id: 1}, session, pos, %{log: fake_log})

    assert_received {:start, %{latitude: 48.87}}
    assert_received {:charge, 999, _}
    assert_received {:complete, 999}
  end
end
