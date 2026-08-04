defmodule TeslaMate.FleetTelemetry.StreamProviderTest do
  use ExUnit.Case, async: true
  alias TeslaMate.FleetTelemetry.StreamProvider
  alias TeslaApi.Stream.Data, as: StreamData

  defp start(opts) do
    test_pid = self()
    receiver = fn sd -> send(test_pid, {:stream, sd}) end

    {:ok, pid} =
      StreamProvider.start_link(
        Keyword.merge([car_id: 1, vin: "VINTEST", receiver: receiver, connect?: false], opts)
      )

    pid
  end

  test "emittiert %Stream.Data{} erst beim Location-Trigger" do
    pid = start([])
    StreamProvider.ingest(pid, "VehicleSpeed", 42.0)
    StreamProvider.ingest(pid, "Gear", "ShiftStateD")
    refute_receive {:stream, _}, 50

    StreamProvider.ingest(pid, "Location", %{"latitude" => 48.39, "longitude" => 10.86})
    assert_receive {:stream, %StreamData{} = sd}, 200
    assert sd.shift_state == "D"
    assert sd.speed == 42.0
    assert sd.est_lat == 48.39
  end

  test "sendet das :fleet_streaming Freshness-Signal nach den Stream-Daten" do
    pid = start([])
    StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
    # Reihenfolge: erst die Stream-Daten, dann der Freshness-Ping
    assert_receive {:stream, %StreamData{}}, 200
    assert_receive {:stream, :fleet_streaming}, 200
  end

  test "Stall beendet den Prozess NICHT - bleibt subscribed und nimmt den Feed wieder auf" do
    pid = start(stall_ms: 60)
    ref = Process.monitor(pid)

    StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
    assert_receive {:stream, %StreamData{}}, 200
    assert_receive {:stream, :fleet_streaming}, 200

    # > stall_ms ohne Daten: Prozess lebt weiter, kein Fallback-durch-Tod mehr
    refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
    assert Process.alive?(pid)

    # Daten kehren zurueck -> Live-Feed wird automatisch wieder aufgenommen
    StreamProvider.ingest(pid, "Location", %{"latitude" => 3.0, "longitude" => 4.0})
    assert_receive {:stream, %StreamData{est_lat: 3.0}}, 200
    assert_receive {:stream, :fleet_streaming}, 200
  end

  test "stop/1 ist idempotent auch bei totem Pid" do
    pid = start([])
    assert StreamProvider.stop(pid) == :ok
    assert StreamProvider.stop(pid) == :ok
  end

  test "stop/1 raeumt ohne Connection sauber auf (terminate ohne client_id)" do
    pid = start([])
    ref = Process.monitor(pid)
    assert StreamProvider.stop(pid) == :ok
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 200
  end

  describe "Reconnect-Robustheit (Crash-Loop-Fix)" do
    test "init ueberlebt {:already_started} vom Connect und reisst den FSM nicht mit" do
      cf = fn _client_id -> {:error, {:already_started, self()}} end
      pid = start(connect?: true, connect_fun: cf)

      assert Process.alive?(pid)

      # Feed funktioniert trotzdem (ingest ist broker-unabhaengig)
      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      assert_receive {:stream, %StreamData{est_lat: 1.0}}, 200
    end

    test "init ueberlebt einen Connect-Fehler und laeuft degraded weiter" do
      cf = fn _client_id -> {:error, :econnrefused} end
      pid = start(connect?: true, connect_fun: cf)

      assert Process.alive?(pid)
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
    end

    test "jede Instanz verwendet eine eindeutige client_id" do
      test_pid = self()
      cf = fn client_id -> send(test_pid, {:cid, client_id}); {:ok, self()} end

      start(connect?: true, connect_fun: cf)
      start(connect?: true, connect_fun: cf)

      assert_receive {:cid, id1}, 200
      assert_receive {:cid, id2}, 200
      assert id1 != id2
      assert String.starts_with?(id1, "TESLAMATE_FLEETSTREAM_VINTEST_")
      assert String.starts_with?(id2, "TESLAMATE_FLEETSTREAM_VINTEST_")
    end
  end

  describe "map_fun (Charge-Feed-Reuse)" do
    test "map_fun wird fuer das emittierte Objekt genutzt" do
      me = self()

      {:ok, pid} =
        StreamProvider.start_link(
          car_id: 1,
          vin: "V",
          connect?: false,
          receiver: fn x -> send(me, {:got, x}) end,
          trigger_field: "DetailedChargeState",
          map_fun: fn fields, _now -> {:charge, Map.get(fields, "DetailedChargeState")} end
        )

      StreamProvider.ingest(pid, "DetailedChargeState", "DetailedChargeStateCharging")
      assert_receive {:got, {:charge, "DetailedChargeStateCharging"}}, 200
      assert_receive {:got, :fleet_streaming}, 200
    end

    test "ohne map_fun bleibt der Default to_stream_data (Fahr-Feed unveraendert)" do
      me = self()

      {:ok, pid} =
        StreamProvider.start_link(
          car_id: 1,
          vin: "V",
          connect?: false,
          receiver: fn x -> send(me, {:got, x}) end
        )

      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      assert_receive {:got, %StreamData{est_lat: 1.0}}, 200
      assert_receive {:got, :fleet_streaming}, 200
    end
  end

  describe "Warm-up-Gate (require_fields)" do
    test "ohne require_fields wird sofort emittiert (Default unveraendert)" do
      pid = start([])
      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      assert_receive {:stream, %StreamData{odometer: nil}}, 200
    end

    test "haelt den ersten Emit zurueck, bis das Pflichtfeld da ist" do
      pid = start(require_fields: ["Odometer"])

      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      refute_receive {:stream, _}, 100

      StreamProvider.ingest(pid, "Odometer", 64_000.5)
      # Odometer ist kein Trigger -> erst der naechste Location-Event emittiert
      refute_receive {:stream, _}, 50

      StreamProvider.ingest(pid, "Location", %{"latitude" => 3.0, "longitude" => 4.0})
      assert_receive {:stream, %StreamData{est_lat: 3.0, odometer: 64_000.5}}, 200
    end

    test "nach dem ersten Emit greift der Gate nicht mehr" do
      pid = start(require_fields: ["Odometer"])
      StreamProvider.ingest(pid, "Odometer", 1.0)
      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      assert_receive {:stream, %StreamData{}}, 200
      assert_receive {:stream, :fleet_streaming}, 200

      StreamProvider.ingest(pid, "Location", %{"latitude" => 5.0, "longitude" => 6.0})
      assert_receive {:stream, %StreamData{est_lat: 5.0}}, 200
    end

    test "emittiert nach Ablauf von warmup_ms auch ohne Pflichtfeld (degraded statt stumm)" do
      pid = start(require_fields: ["Odometer"], warmup_ms: 60)

      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      refute_receive {:stream, _}, 100

      StreamProvider.ingest(pid, "Location", %{"latitude" => 7.0, "longitude" => 8.0})
      assert_receive {:stream, %StreamData{est_lat: 7.0, odometer: nil}}, 200
    end

    test "Alternativgruppe: eines der Felder genuegt" do
      # Die Lade-Energie kommt als DC- ODER AC-Feld. Beide zu fordern waere nie erfuellbar,
      # DC-Laden sendet kein AC-Feld und umgekehrt.
      pid = start(require_fields: [["DCChargingEnergyIn", "ACChargingEnergyIn"]])

      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      refute_receive {:stream, _}, 100

      StreamProvider.ingest(pid, "ACChargingEnergyIn", 1.78)
      StreamProvider.ingest(pid, "Location", %{"latitude" => 3.0, "longitude" => 4.0})
      assert_receive {:stream, %StreamData{est_lat: 3.0}}, 200
    end

    test "Alternativgruppe: das andere Feld genuegt genauso" do
      pid = start(require_fields: [["DCChargingEnergyIn", "ACChargingEnergyIn"]])

      StreamProvider.ingest(pid, "DCChargingEnergyIn", 4.2)
      StreamProvider.ingest(pid, "Location", %{"latitude" => 5.0, "longitude" => 6.0})
      assert_receive {:stream, %StreamData{est_lat: 5.0}}, 200
    end

    test "Einzelfeld und Alternativgruppe zusammen: beide Bedingungen muessen erfuellt sein" do
      pid = start(require_fields: ["IdealBatteryRange", ["DCChargingEnergyIn", "ACChargingEnergyIn"]])

      StreamProvider.ingest(pid, "ACChargingEnergyIn", 1.78)
      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      refute_receive {:stream, _}, 100

      StreamProvider.ingest(pid, "IdealBatteryRange", 115.0)
      StreamProvider.ingest(pid, "Location", %{"latitude" => 7.0, "longitude" => 8.0})
      assert_receive {:stream, %StreamData{est_lat: 7.0}}, 200
    end

    test "emit_always laesst das Ereignis trotz fehlendem Pflichtfeld sofort durch" do
      me = self()

      {:ok, pid} =
        StreamProvider.start_link(
          car_id: 1,
          vin: "V",
          connect?: false,
          receiver: fn x -> send(me, {:got, x}) end,
          trigger_field: "DetailedChargeState",
          map_fun: fn fields, _now -> {:charge, Map.get(fields, "DetailedChargeState")} end,
          require_fields: ["IdealBatteryRange"],
          emit_always: fn field, value ->
            field == "DetailedChargeState" and String.contains?(value, "Stopped")
          end
        )

      # laufende Ladung ohne Pflichtfeld -> zurueckgehalten
      StreamProvider.ingest(pid, "DetailedChargeState", "DetailedChargeStateCharging")
      refute_receive {:got, _}, 100

      # Lade-ENDE -> muss durch, sonst bleibt der charging_process offen
      StreamProvider.ingest(pid, "DetailedChargeState", "DetailedChargeStateStopped")
      assert_receive {:got, {:charge, "DetailedChargeStateStopped"}}, 200
    end
  end

  describe "Harte Pflichtfelder (require_hard) - kein Timeout-Bypass" do
    test "der warmup_ms-Timeout ueberbrueckt ein hartes Pflichtfeld NICHT" do
      pid = start(require_hard: ["IdealBatteryRange"], warmup_ms: 40)

      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      refute_receive {:stream, _}, 100

      # nach Ablauf des Fensters weiterhin still - anders als bei require_fields
      StreamProvider.ingest(pid, "Location", %{"latitude" => 7.0, "longitude" => 8.0})
      refute_receive {:stream, _}, 100
    end

    test "sobald das harte Feld da ist, oeffnet der Gate" do
      pid = start(require_hard: ["IdealBatteryRange"], warmup_ms: 40)

      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      refute_receive {:stream, _}, 100

      StreamProvider.ingest(pid, "IdealBatteryRange", 115.07)
      StreamProvider.ingest(pid, "Location", %{"latitude" => 3.0, "longitude" => 4.0})
      assert_receive {:stream, %StreamData{est_lat: 3.0}}, 200
    end

    test "harte Alternativgruppe: eines der Felder genuegt, der Timeout ersetzt keines" do
      pid = start(require_hard: [["DCChargingEnergyIn", "ACChargingEnergyIn"]], warmup_ms: 40)

      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      refute_receive {:stream, _}, 100

      StreamProvider.ingest(pid, "ACChargingEnergyIn", 1.78)
      StreamProvider.ingest(pid, "Location", %{"latitude" => 5.0, "longitude" => 6.0})
      assert_receive {:stream, %StreamData{est_lat: 5.0}}, 200
    end

    test "weich und hart gemischt: der Timeout ueberbrueckt nur das weiche Feld" do
      pid = start(require_fields: ["Odometer"], require_hard: ["IdealBatteryRange"], warmup_ms: 40)

      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      refute_receive {:stream, _}, 100

      # Timeout abgelaufen, aber das harte Feld fehlt -> weiter still
      StreamProvider.ingest(pid, "Location", %{"latitude" => 3.0, "longitude" => 4.0})
      refute_receive {:stream, _}, 100

      # nur das harte Feld nachliefern: Odometer bleibt leer, emittiert wird trotzdem
      StreamProvider.ingest(pid, "IdealBatteryRange", 115.07)
      StreamProvider.ingest(pid, "Location", %{"latitude" => 9.0, "longitude" => 10.0})
      assert_receive {:stream, %StreamData{est_lat: 9.0, odometer: nil}}, 200
    end

    test "emit_always bleibt die Ausnahme auch fuer harte Felder (Lade-Ende)" do
      me = self()

      {:ok, pid} =
        StreamProvider.start_link(
          car_id: 1,
          vin: "V",
          connect?: false,
          receiver: fn x -> send(me, {:got, x}) end,
          trigger_field: "DetailedChargeState",
          map_fun: fn fields, _now -> {:charge, Map.get(fields, "DetailedChargeState")} end,
          require_hard: ["IdealBatteryRange"],
          emit_always: fn field, value ->
            field == "DetailedChargeState" and String.contains?(value, "Stopped")
          end
        )

      StreamProvider.ingest(pid, "DetailedChargeState", "DetailedChargeStateCharging")
      refute_receive {:got, _}, 100

      StreamProvider.ingest(pid, "DetailedChargeState", "DetailedChargeStateStopped")
      assert_receive {:got, {:charge, "DetailedChargeStateStopped"}}, 200
    end

    test "Default unveraendert: ohne require_hard wird der Timeout weiter genutzt" do
      pid = start(require_fields: ["Odometer"], warmup_ms: 40)

      StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
      refute_receive {:stream, _}, 100

      StreamProvider.ingest(pid, "Location", %{"latitude" => 7.0, "longitude" => 8.0})
      assert_receive {:stream, %StreamData{est_lat: 7.0, odometer: nil}}, 200
    end
  end

  describe "Grund im degradierten Emit" do
    # config/test.exs setzt `level: :warning` - die Info-Zeile wird sonst gefiltert, bevor
    # capture_log sie sieht. Nur fuer diesen Block angehoben und danach zurueckgestellt.
    setup do
      vorher = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: vorher) end)
      :ok
    end

    test "der Timeout wird als Timeout benannt" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          pid = start(require_fields: ["Odometer"], warmup_ms: 40)
          StreamProvider.ingest(pid, "Location", %{"latitude" => 1.0, "longitude" => 2.0})
          refute_receive {:stream, _}, 80
          StreamProvider.ingest(pid, "Location", %{"latitude" => 7.0, "longitude" => 8.0})
          assert_receive {:stream, %StreamData{est_lat: 7.0}}, 200
        end)

      assert log =~ "emittiere degraded (Timeout"
      refute log =~ "emit_always"
    end

    test "die emit_always-Ausnahme wird als Ausnahme benannt, nicht als Timeout" do
      me = self()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, pid} =
            StreamProvider.start_link(
              car_id: 1,
              vin: "V",
              connect?: false,
              receiver: fn x -> send(me, {:got, x}) end,
              trigger_field: "DetailedChargeState",
              map_fun: fn fields, _now -> {:charge, Map.get(fields, "DetailedChargeState")} end,
              require_hard: ["IdealBatteryRange"],
              emit_always: fn field, value ->
                field == "DetailedChargeState" and String.contains?(value, "Stopped")
              end
            )

          StreamProvider.ingest(pid, "DetailedChargeState", "DetailedChargeStateStopped")
          assert_receive {:got, _}, 200
        end)

      assert log =~ "emittiere degraded (Ausnahme emit_always)"
      refute log =~ "(Timeout"
    end
  end

  describe "fleet_driving_interval" do
    test "default 180s" do
      assert TeslaMate.Vehicles.Vehicle.fleet_driving_interval() == 180
    end
  end
end
