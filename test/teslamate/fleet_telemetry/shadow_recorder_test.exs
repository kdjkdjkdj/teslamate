defmodule TeslaMate.FleetTelemetry.ShadowRecorderTest do
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.{ShadowRecorder, Mapper, FieldState}

  setup do
    test_pid = self()
    sink = fn attrs -> send(test_pid, {:snapshot, attrs}) end
    {:ok, pid} = ShadowRecorder.start_link(car_id: 1, sink: sink, name: nil)
    %{pid: pid}
  end

  test "materialisiert Snapshot erst beim Location-Trigger", %{pid: pid} do
    ShadowRecorder.ingest(pid, "VehicleSpeed", 47.22)
    ShadowRecorder.ingest(pid, "PackVoltage", 391.31)
    ShadowRecorder.ingest(pid, "PackCurrent", 138.8)
    refute_receive {:snapshot, _}, 50

    ShadowRecorder.ingest(pid, "Location", %{"latitude" => 48.39, "longitude" => 10.86})
    assert_receive {:snapshot, attrs}, 200
    assert attrs.car_id == 1
    assert attrs.power == -54
    assert attrs.latitude == 48.39
    assert attrs.fields_present >= 4
  end

  test "rollender Zustand bleibt ueber mehrere Snapshots erhalten", %{pid: pid} do
    ShadowRecorder.ingest(pid, "BatteryLevel", 64.0)
    ShadowRecorder.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
    assert_receive {:snapshot, a1}, 200
    assert a1.battery_level == 64

    # nur Location erneut -> BatteryLevel kommt weiter aus rollendem Zustand
    ShadowRecorder.ingest(pid, "Location", %{"latitude" => 1.1, "longitude" => 2.1})
    assert_receive {:snapshot, a2}, 200
    assert a2.battery_level == 64
    assert a2.latitude == 1.1
  end
  test "Sink-Fehler crasht den GenServer nicht; folgende Snapshots gelingen weiter" do
    test_pid = self()

    sink = fn attrs ->
      if attrs.latitude == 0.0 do
        raise "boom"
      else
        send(test_pid, {:snapshot, attrs})
      end
    end

    {:ok, pid} = ShadowRecorder.start_link(car_id: 2, sink: sink, name: nil)

    # Erster Snapshot laesst den Sink crashen
    ShadowRecorder.ingest(pid, "Location", %{"latitude" => 0.0, "longitude" => 0.0})
    refute_receive {:snapshot, _}, 50
    assert Process.alive?(pid)

    # Recorder lebt weiter -> naechster Snapshot gelingt
    ShadowRecorder.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
    assert_receive {:snapshot, attrs}, 200
    assert attrs.latitude == 1.0
  end

  test "ohne explizite sink wird Writer.write genutzt" do
    test_pid = self()
    {:ok, _} = TeslaMate.FleetTelemetry.Writer.start_link(insert_fun: fn a -> send(test_pid, {:written, a}) end)
    {:ok, pid} = ShadowRecorder.start_link(car_id: 7, name: nil)

    ShadowRecorder.ingest(pid, "Location", %{"latitude" => 5.0, "longitude" => 6.0})
    assert_receive {:written, attrs}, 200
    assert attrs.car_id == 7
    assert attrs.latitude == 5.0
  end

  describe "Charge-Recorder (map_fun + gate_fun)" do
    setup do
      test_pid = self()
      sink = fn attrs -> send(test_pid, {:charge, attrs}) end

      {:ok, pid} =
        ShadowRecorder.start_link(
          car_id: 1,
          name: nil,
          sink: sink,
          trigger_field: ~w(DCChargingEnergyIn ACChargingEnergyIn DetailedChargeState),
          map_fun: &Mapper.to_charge_attrs/3,
          gate_fun: fn fs -> Mapper.charging_lifecycle?(FieldState.get(fs, "DetailedChargeState")) end
        )

      %{pid: pid}
    end

    test "Gate blockt ohne Lade-Lifecycle-State (Fahren/Parken -> keine Zeile)", %{pid: pid} do
      # Energy-Trigger ohne DetailedChargeState -> Gate false
      ShadowRecorder.ingest(pid, "DCChargingEnergyIn", 5.0)
      refute_receive {:charge, _}, 50

      # DetailedChargeState Disconnected -> Trigger, aber Gate false
      ShadowRecorder.ingest(pid, "DetailedChargeState", "DetailedChargeStateDisconnected")
      refute_receive {:charge, _}, 50
    end

    test "materialisiert bei Charging + Energy-Trigger", %{pid: pid} do
      ShadowRecorder.ingest(pid, "DetailedChargeState", "DetailedChargeStateCharging")
      # DetailedChargeState ist selbst Trigger + Gate true -> erster Snapshot
      assert_receive {:charge, a1}, 200
      assert a1.car_id == 1
      assert a1.charging_state == "DetailedChargeStateCharging"

      ShadowRecorder.ingest(pid, "DCChargingPower", 66.0)
      ShadowRecorder.ingest(pid, "DCChargingEnergyIn", 12.0)
      assert_receive {:charge, a2}, 200
      assert a2.charge_source == "dc"
      assert a2.charger_power == 66
      assert a2.charge_energy_added == 12.0
    end
  end
end
