defmodule TeslaMate.Vehicles.Vehicle.ChargeThrottleTest do
  # Pure Unit-Tests fuer die Charge-Feed-Freshness/Throttle-Helfer. Eigene Datei (statt
  # VehicleCase), damit die FLEET_TELEMETRY_*-Env-Manipulation nicht in die Integrationstests
  # blutet - analog fleet_gear_seed_test.exs.
  use ExUnit.Case, async: false

  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.Vehicles.Vehicle.Data
  alias TeslaMate.Log.Car

  setup do
    System.put_env("FLEET_TELEMETRY_FEED_CHARGING", "true")
    System.put_env("FLEET_TELEMETRY_VIN", "CHARGEVIN")

    on_exit(fn ->
      System.delete_env("FLEET_TELEMETRY_FEED_CHARGING")
      System.delete_env("FLEET_TELEMETRY_VIN")
      System.delete_env("POLLING_FLEET_CHARGING_INTERVAL")
    end)

    :ok
  end

  defp fresh_data do
    %Data{
      car: %Car{vin: "CHARGEVIN"},
      charge_stream_pid: self(),
      last_charge_stream_at: DateTime.utc_now()
    }
  end

  describe "fleet_charge_feed_enabled?/1" do
    test "true nur mit Flag + passender VIN" do
      assert Vehicle.fleet_charge_feed_enabled?(%Data{car: %Car{vin: "CHARGEVIN"}})
    end

    test "false ohne Flag" do
      System.delete_env("FLEET_TELEMETRY_FEED_CHARGING")
      refute Vehicle.fleet_charge_feed_enabled?(%Data{car: %Car{vin: "CHARGEVIN"}})
    end

    test "false bei VIN-Mismatch" do
      refute Vehicle.fleet_charge_feed_enabled?(%Data{car: %Car{vin: "OTHER"}})
    end

    test "ist unabhaengig vom Fahr-Feed-Flag (FLEET_TELEMETRY_FEED)" do
      System.delete_env("FLEET_TELEMETRY_FEED")
      assert Vehicle.fleet_charge_feed_enabled?(%Data{car: %Car{vin: "CHARGEVIN"}})
    end
  end

  describe "charge_poll_interval/2" do
    test "gedrosselt (Default 300) bei frischem Feed" do
      assert Vehicle.charge_poll_interval(fresh_data(), 11) == 300
    end

    test "ehrt POLLING_FLEET_CHARGING_INTERVAL" do
      System.put_env("POLLING_FLEET_CHARGING_INTERVAL", "420")
      assert Vehicle.charge_poll_interval(fresh_data(), 11) == 420
    end

    test "faellt auf determince_interval zurueck ohne Feed-Provider" do
      # determince_interval(11) = round(250/11)=23 |> min(20)=20 |> max(charging_interval()=5)
      data = %Data{car: %Car{vin: "CHARGEVIN"}}
      assert Vehicle.charge_poll_interval(data, 11) == 20
    end

    test "staler Feed (Timestamp zu alt) -> determince_interval" do
      old = DateTime.add(DateTime.utc_now(), -60, :second)
      data = %{fresh_data() | last_charge_stream_at: old}
      assert Vehicle.charge_poll_interval(data, 11) == 20
    end

    test "Flag aus -> determince_interval trotz frischem Timestamp" do
      System.delete_env("FLEET_TELEMETRY_FEED_CHARGING")
      assert Vehicle.charge_poll_interval(fresh_data(), 11) == 20
    end
  end

  describe "charge_energy_added/2 (Poll- und Feed-Zeilen aus einer Quelle)" do
    # Der REST-Wert ist auf 0,1 kWh gerundet; der Feed-Wert kommt aus ACChargingEnergyIn.
    # Gemessen an #392 (2026-08-05): 0,10 gegen 0,118 zum selben Zeitpunkt.
    defp poll_vehicle(kwh) do
      %TeslaApi.Vehicle{charge_state: %TeslaApi.Vehicle.State.Charge{charge_energy_added: kwh}}
    end

    test "frischer Feed: Poll-Zeile traegt den Feed-Wert, nicht den gerundeten REST-Wert" do
      data = %{fresh_data() | last_charge_stream_energy: 0.118}
      assert Vehicle.charge_energy_added(poll_vehicle(0.10), data) == 0.118
    end

    test "ohne Feed-Wert bleibt es beim REST-Wert" do
      assert Vehicle.charge_energy_added(poll_vehicle(0.10), fresh_data()) == 0.10
    end

    test "staler Feed -> REST-Wert, damit die Sitzung aus EINER Quelle bleibt" do
      old = DateTime.add(DateTime.utc_now(), -60, :second)
      data = %{fresh_data() | last_charge_stream_at: old, last_charge_stream_energy: 0.118}
      assert Vehicle.charge_energy_added(poll_vehicle(0.10), data) == 0.10
    end

    test "Flag aus -> REST-Wert" do
      System.delete_env("FLEET_TELEMETRY_FEED_CHARGING")
      data = %{fresh_data() | last_charge_stream_energy: 0.118}
      assert Vehicle.charge_energy_added(poll_vehicle(0.10), data) == 0.10
    end

    test "nil im Feed-Wert faellt nicht auf nil durch" do
      # Die terminale Stopped/Complete-Kante darf ohne Energie ankommen. Sie darf den
      # Poll-Wert aber nicht loeschen - sonst verwirft der Changeset die Zeile.
      data = %{fresh_data() | last_charge_stream_energy: nil}
      assert Vehicle.charge_energy_added(poll_vehicle(0.10), data) == 0.10
    end
  end
end
