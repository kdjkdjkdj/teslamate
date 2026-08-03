defmodule TeslaMate.Vehicles.Vehicle.ChargingTest do
  use TeslaMate.VehicleCase, async: false

  alias TeslaMate.Vehicles.Vehicle.Summary
  alias TeslaMate.Log.ChargingProcess

  import ExUnit.CaptureLog

  @log_opts format: "[$level] $message\n",
            colors: [enabled: false]

  test "logs a full charging cycle", %{test: name} do
    now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    events = [
      {:ok, online_event(now_ts)},
      {:ok,
       online_event(now_ts, drive_state: %{timestamp: now_ts, latitude: 0.0, longitude: 0.0})},
      {:ok, charging_event(now_ts + 1, "Starting", 0.1, range: 1)},
      {:ok, charging_event(now_ts + 2, "Charging", 0.2, range: 2)},
      {:ok, charging_event(now_ts + 3, "Charging", 0.3, range: 3)},
      {:ok, charging_event(now_ts + 4, "Complete", 0.4, range: 4)},
      {:ok, charging_event(now_ts + 5, "Complete", 0.4, range: 4)},
      {:ok, charging_event(now_ts + 6, "Unplugged", 0.4, range: 4)},
      {:ok,
       online_event(now_ts + 7,
         drive_state: %{timestamp: now_ts + 7, latitude: 0.2, longitude: 0.2}
       )},
      fn -> Process.sleep(10_000) end
    ]

    :ok = start_vehicle(name, events)

    start_date = DateTime.from_unix!(now_ts, :millisecond)
    assert_receive {:start_state, car, :online, date: ^start_date}, 400
    assert_receive {ApiMock, {:stream, 1000, _}}
    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online, since: s0}}}

    assert_receive {:start_charging_process, ^car, %{latitude: +0.0, longitude: +0.0},
                    [lookup_address: true]}

    assert_receive {:"$websockex_cast", :disconnect}

    assert_receive {:insert_charge, %ChargingProcess{id: _process_id} = cproc,
                    %{
                      date: _,
                      charge_energy_added: 0.1,
                      rated_battery_range_km: 1.61,
                      ideal_battery_range_km: 1.61
                    }}

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging, since: s1}}}
    assert DateTime.diff(s0, s1, :nanosecond) < 0

    assert_receive {:insert_charge, ^cproc,
                    %{
                      date: _,
                      charge_energy_added: 0.2,
                      rated_battery_range_km: 3.22,
                      ideal_battery_range_km: 3.22
                    }}

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging, since: ^s1}}}

    assert_receive {:insert_charge, ^cproc,
                    %{
                      date: _,
                      charge_energy_added: 0.3,
                      rated_battery_range_km: 4.83,
                      ideal_battery_range_km: 4.83
                    }}

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging, since: ^s1}}}

    assert_receive {:insert_position, ^car, %{}}

    assert_receive {:insert_charge, ^cproc,
                    %{
                      date: _,
                      charge_energy_added: 0.4,
                      rated_battery_range_km: 6.44,
                      ideal_battery_range_km: 6.44
                    }}

    # Completed
    assert_receive {:complete_charging_process, ^cproc}

    start_date = DateTime.from_unix!(now_ts + 4, :millisecond)
    assert_receive {:start_state, ^car, :online, date: ^start_date}
    assert_receive {ApiMock, {:stream, 1000, _}}
    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online, since: s2}}}
    assert DateTime.diff(s1, s2, :nanosecond) < 0

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online, since: ^s2}}}

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}
    refute_receive _
  end

  @tag :capture_log
  test "handles a connection loss when charging", %{test: name} do
    now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    events = [
      {:ok, online_event(now_ts)},
      {:ok,
       online_event(now_ts, drive_state: %{timestamp: now_ts, latitude: +0.0, longitude: +0.0})},
      {:ok, charging_event(now_ts + 1, "Charging", 0.1)},
      {:ok, charging_event(now_ts + 2, "Charging", 0.2)},
      {:error, :vehicle_unavailable},
      {:ok, %TeslaApi.Vehicle{state: "offline"}},
      {:error, :vehicle_unavailable},
      {:ok, %TeslaApi.Vehicle{state: "unknown"}},
      {:ok, charging_event(now_ts + 3, "Charging", 0.3)},
      {:ok, charging_event(now_ts + 4, "Complete", 0.3)},
      {:ok, charging_event(now_ts + 5, "Complete", 0.3)},
      {:ok, charging_event(now_ts + 6, "Unplugged", 0.3)},
      {:ok,
       online_event(now_ts + 7,
         drive_state: %{timestamp: now_ts + 7, latitude: 0.2, longitude: 0.2}
       )},
      fn -> Process.sleep(10_000) end
    ]

    :ok = start_vehicle(name, events)

    start_date = DateTime.from_unix!(now_ts, :millisecond)
    assert_receive {:start_state, car, :online, date: ^start_date}
    assert_receive {ApiMock, {:stream, 1000, _}}
    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}

    assert_receive {:start_charging_process, ^car, %{latitude: +0.0, longitude: +0.0},
                    [lookup_address: true]}

    assert_receive {:"$websockex_cast", :disconnect}

    assert_receive {:insert_charge, %ChargingProcess{id: _cproc_id} = cproc,
                    %{date: _, charge_energy_added: 0.1}}

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging}}}

    assert_receive {:insert_charge, ^cproc, %{date: _, charge_energy_added: 0.2}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging}}}

    assert_receive {:insert_charge, ^cproc, %{date: _, charge_energy_added: 0.3}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging}}}

    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:insert_charge, ^cproc, %{date: _, charge_energy_added: 0.3}}
    assert_receive {:complete_charging_process, ^cproc}

    start_date = DateTime.from_unix!(now_ts + 4, :millisecond)
    assert_receive {:start_state, ^car, :online, date: ^start_date}
    assert_receive {ApiMock, {:stream, 1000, _}}
    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}
    refute_receive _
  end

  test "handles a invalid charge data", %{test: name} do
    now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    events = [
      {:ok, online_event(now_ts)},
      {:ok,
       online_event(now_ts, drive_state: %{timestamp: now_ts, latitude: +0.0, longitude: +0.0})},
      {:ok, charging_event(now_ts + 1, "Charging", 0.1)},
      {:ok, %TeslaApi.Vehicle{state: "online", charge_state: nil}},
      {:ok, %TeslaApi.Vehicle{state: "online", charge_state: nil}},
      {:ok, %TeslaApi.Vehicle{state: "online", charge_state: nil}},
      {:ok, charging_event(now_ts + 3, "Charging", 0.3)},
      {:ok, charging_event(now_ts + 5, "Complete", 0.3)},
      {:ok,
       online_event(now_ts + 6,
         drive_state: %{timestamp: now_ts + 6, latitude: 0.2, longitude: 0.2}
       )},
      fn -> Process.sleep(10_000) end
    ]

    :ok = start_vehicle(name, events, settings: %{use_streaming_api: false})

    start_date = DateTime.from_unix!(now_ts, :millisecond)
    assert_receive {:start_state, car, :online, date: ^start_date}
    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}

    assert_receive {:start_charging_process, ^car, %{latitude: +0.0, longitude: +0.0},
                    [lookup_address: true]}

    assert_receive {:insert_charge, cproc, %{date: _, charge_energy_added: 0.1}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging}}}

    assert capture_log(@log_opts, fn ->
             assert_receive {:insert_charge, ^cproc, %{date: _, charge_energy_added: 0.3}}
             assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging}}}
           end) =~ "Discarded incomplete fetch result"

    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:insert_charge, ^cproc, %{date: _, charge_energy_added: 0.3}}
    assert_receive {:complete_charging_process, ^cproc}

    start_date = DateTime.from_unix!(now_ts + 5, :millisecond)
    assert_receive {:start_state, ^car, :online, date: ^start_date}
    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}

    refute_receive _
  end

  test "Transitions directly into charging state", %{test: name} do
    now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    events = [
      {:ok, online_event(now_ts)},
      {:ok, charging_event(now_ts, "Charging", 22)},
      fn -> Process.sleep(10_000) end
    ]

    :ok = start_vehicle(name, events)

    start_date = DateTime.from_unix!(now_ts, :millisecond)
    assert_receive {:start_state, car, :online, date: ^start_date}
    assert_receive {ApiMock, {:stream, 1000, _}}
    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}

    assert_receive {:start_charging_process, ^car, %{latitude: +0.0, longitude: +0.0},
                    [lookup_address: true]}

    assert_receive {:"$websockex_cast", :disconnect}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging}}}
    assert_receive {:insert_charge, _charging_event, %{date: _, charge_energy_added: 22}}

    refute_received _
  end

  @tag :capture_log
  test "transitions into asleep state", %{test: name} do
    now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

    events = [
      {:ok, online_event(now_ts)},
      {:ok,
       online_event(now_ts, drive_state: %{timestamp: now_ts, latitude: +0.0, longitude: +0.0})},
      {:ok, charging_event(now_ts + 1, "Charging", 0.1)},
      {:ok, charging_event(now_ts + 2, "Charging", 0.2)},
      {:error, :vehicle_unavailable},
      {:ok, %TeslaApi.Vehicle{state: "asleep"}},
      fn -> Process.sleep(10_000) end
    ]

    :ok = start_vehicle(name, events)

    start_date = DateTime.from_unix!(now_ts, :millisecond)
    assert_receive {:start_state, car, :online, date: ^start_date}
    assert_receive {ApiMock, {:stream, 1000, _}}
    assert_receive {:insert_position, ^car, %{}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}

    assert_receive {:start_charging_process, ^car, %{latitude: +0.0, longitude: +0.0},
                    [lookup_address: true]}

    assert_receive {:"$websockex_cast", :disconnect}

    assert_receive {:insert_charge, %ChargingProcess{id: _cproc_id} = cproc,
                    %{date: _, charge_energy_added: 0.1}}

    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging}}}
    assert_receive {:insert_charge, ^cproc, %{date: _, charge_energy_added: 0.2}}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :charging}}}
    assert_receive {:complete_charging_process, ^cproc}
    assert_receive {:start_state, ^car, :asleep, []}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :asleep}}}

    refute_receive _
  end

  describe "merge_charge/3" do
    test "uebernimmt Ladefelder aus dem Snapshot, laesst climate unberuehrt" do
      vehicle = %TeslaApi.Vehicle{
        charge_state: %TeslaApi.Vehicle.State.Charge{
          charging_state: "Charging",
          battery_level: 50,
          usable_battery_level: 49,
          charger_power: 2,
          charge_energy_added: 1.0,
          ideal_battery_range: 100.0,
          battery_range: 100.0,
          timestamp: 1000
        },
        climate_state: %TeslaApi.Vehicle.State.Climate{outside_temp: 21.5, inside_temp: 22.0}
      }

      cs = %TeslaMate.FleetTelemetry.ChargeStream{
        time: ~U[2026-07-12 12:18:56Z],
        charging_state: "DetailedChargeStateStopped",
        charger_power: 11,
        charger_voltage: 224,
        charger_actual_current: 16,
        charger_phases: 2,
        charge_energy_added: 24.8,
        battery_level: 63,
        usable_battery_level: 62,
        ideal_battery_range_km: 297.7,
        rated_battery_range_km: 297.7,
        fast_charger_present: false,
        fast_charger_type: "ACSingleWireCAN"
      }

      merged = TeslaMate.Vehicles.Vehicle.merge_charge(vehicle, cs, time: true)

      assert merged.charge_state.charging_state == "DetailedChargeStateStopped"
      assert merged.charge_state.charger_power == 11
      assert merged.charge_state.charger_voltage == 224
      assert merged.charge_state.charger_actual_current == 16
      assert merged.charge_state.charger_phases == 2
      assert merged.charge_state.charge_energy_added == 24.8
      assert merged.charge_state.battery_level == 63
      assert merged.charge_state.usable_battery_level == 62
      assert merged.charge_state.fast_charger_present == false
      assert merged.charge_state.fast_charger_type == "ACSingleWireCAN"
      # km -> mi zurueck (insert_charge rechnet selbst wieder in km)
      assert_in_delta merged.charge_state.ideal_battery_range, 185.0, 0.5
      assert_in_delta merged.charge_state.battery_range, 185.0, 0.5
      # timestamp aus cs.time (opts[:time])
      assert merged.charge_state.timestamp ==
               DateTime.to_unix(~U[2026-07-12 12:18:56Z], :millisecond)
      # climate unangetastet
      assert merged.climate_state.outside_temp == 21.5
      assert merged.climate_state.inside_temp == 22.0
    end

    test "ein nil aus dem Feed loescht die gepollten Ranges nicht" do
      # Sessionbeginn: der Feed hat IdealBatteryRange/RatedRange noch nicht geliefert.
      # ideal_battery_range_km steht in Charge.changeset unter validate_required - wuerde
      # der Merge den gepollten Wert mit nil ueberschreiben, verwirft insert_charge die
      # ganze Kurvenzeile.
      vehicle = %TeslaApi.Vehicle{
        charge_state: %TeslaApi.Vehicle.State.Charge{
          charging_state: "Charging",
          ideal_battery_range: 185.0,
          battery_range: 186.0,
          timestamp: 1000
        }
      }

      cs = %TeslaMate.FleetTelemetry.ChargeStream{
        time: ~U[2026-08-03 12:56:17Z],
        charging_state: "DetailedChargeStateCharging",
        charger_power: 11,
        ideal_battery_range_km: nil,
        rated_battery_range_km: nil
      }

      merged = TeslaMate.Vehicles.Vehicle.merge_charge(vehicle, cs, time: true)

      assert merged.charge_state.ideal_battery_range == 185.0
      assert merged.charge_state.battery_range == 186.0
      # der Rest kommt weiter aus dem Feed
      assert merged.charge_state.charger_power == 11
      assert merged.charge_state.charging_state == "DetailedChargeStateCharging"
    end

    test "nil bei Phasen/Strom/Spannung/SoC behaelt die gepollten Werte" do
      # ChargerPhases (60 s) und ChargeAmps (30 s) kommen onChange und aendern sich bei
      # konstantem AC-Laden nie -> sie erreichen den frischen FieldState einer Session nie.
      # Wuerde das nil durchgeschrieben, waere die Session inhomogen und TeslaMates
      # Energie-Integration verzweigt je Zeile anders (Ladung #381: 3,31 statt 5,37 kWh).
      vehicle = %TeslaApi.Vehicle{
        charge_state: %TeslaApi.Vehicle.State.Charge{
          charging_state: "Charging",
          charger_voltage: 222,
          charger_actual_current: 16,
          charger_phases: 2,
          battery_level: 19,
          usable_battery_level: 18,
          ideal_battery_range: 185.0,
          battery_range: 186.0
        }
      }

      cs = %TeslaMate.FleetTelemetry.ChargeStream{
        time: ~U[2026-08-03 12:56:17Z],
        charging_state: "DetailedChargeStateCharging",
        charger_power: 11,
        charger_voltage: nil,
        charger_actual_current: nil,
        charger_phases: nil,
        battery_level: nil,
        usable_battery_level: nil
      }

      merged = TeslaMate.Vehicles.Vehicle.merge_charge(vehicle, cs, time: true)

      assert merged.charge_state.charger_voltage == 222
      assert merged.charge_state.charger_actual_current == 16
      assert merged.charge_state.charger_phases == 2
      assert merged.charge_state.battery_level == 19
      assert merged.charge_state.usable_battery_level == 18
      # was der Feed liefert, gewinnt weiterhin
      assert merged.charge_state.charger_power == 11
      assert merged.charge_state.charging_state == "DetailedChargeStateCharging"
    end

    test "charging_state wird NICHT fortgeschrieben - eine Phase ist eine Aussage" do
      vehicle = %TeslaApi.Vehicle{
        charge_state: %TeslaApi.Vehicle.State.Charge{charging_state: "Charging"}
      }

      cs = %TeslaMate.FleetTelemetry.ChargeStream{
        time: ~U[2026-08-03 12:56:17Z],
        charging_state: nil
      }

      merged = TeslaMate.Vehicles.Vehicle.merge_charge(vehicle, cs)
      assert merged.charge_state.charging_state == nil
    end

    test "ein Wert aus dem Feed gewinnt gegen den gepollten" do
      vehicle = %TeslaApi.Vehicle{
        charge_state: %TeslaApi.Vehicle.State.Charge{ideal_battery_range: 1.0, battery_range: 1.0}
      }

      cs = %TeslaMate.FleetTelemetry.ChargeStream{
        time: ~U[2026-08-03 12:56:17Z],
        ideal_battery_range_km: 297.7,
        rated_battery_range_km: 297.7
      }

      merged = TeslaMate.Vehicles.Vehicle.merge_charge(vehicle, cs)
      assert_in_delta merged.charge_state.ideal_battery_range, 185.0, 0.5
      assert_in_delta merged.charge_state.battery_range, 185.0, 0.5
    end

    test "ohne opts[:time] bleibt der bestehende timestamp erhalten" do
      vehicle = %TeslaApi.Vehicle{
        charge_state: %TeslaApi.Vehicle.State.Charge{timestamp: 1000, battery_level: 50}
      }

      cs = %TeslaMate.FleetTelemetry.ChargeStream{time: ~U[2026-07-12 12:18:56Z], battery_level: 63}
      merged = TeslaMate.Vehicles.Vehicle.merge_charge(vehicle, cs)
      assert merged.charge_state.timestamp == 1000
      assert merged.charge_state.battery_level == 63
    end
  end

  describe "charge feed :charging (Verdichtung + Ende)" do
    # Bringt den FSM per Poll in {:charging, cproc} und haelt ihn dort (blockierendes
    # Poll-Event), sodass injizierte {:stream_charge, cs}-Nachrichten isoliert wirken.
    defp events_into_charging(me, now_ts, tail) do
      [
        {:ok, online_event(now_ts)},
        {:ok,
         online_event(now_ts, drive_state: %{timestamp: now_ts, latitude: 0.0, longitude: 0.0})},
        {:ok, charging_event(now_ts + 1, "Charging", 0.1, range: 1)},
        fn ->
          send(me, :charging_reached)

          receive do
            :cont -> {:error, :closed}
          after
            5_000 -> raise "no :cont"
          end
        end
      ] ++ tail
    end

    test "{:stream_charge, Charging} verdichtet die Kurve via insert_charge", %{test: name} do
      me = self()
      now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      :ok = start_vehicle(name, events_into_charging(me, now_ts, [fn -> Process.sleep(10_000) end]))

      assert_receive {:start_charging_process, _car, _, _}, 800
      assert_receive {:insert_charge, cproc, %{charge_energy_added: 0.1}}, 800
      assert_receive :charging_reached, 800

      cs = %TeslaMate.FleetTelemetry.ChargeStream{
        time: DateTime.utc_now(),
        charging_state: "DetailedChargeStateCharging",
        charger_power: 11,
        charger_voltage: 224,
        charge_energy_added: 5.5,
        battery_level: 55,
        rated_battery_range_km: 100.0,
        ideal_battery_range_km: 100.0
      }

      send(name, {:stream_charge, cs})

      assert_receive {:insert_charge, ^cproc,
                      %{charge_energy_added: 5.5, charger_power: 11, battery_level: 55}},
                     800
    end

    test "{:stream_charge, Stopped} beendet die Ladung feed-getrieben", %{test: name} do
      me = self()
      now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      tail = [
        {:ok,
         online_event(now_ts + 9,
           drive_state: %{timestamp: now_ts + 9, latitude: 0.2, longitude: 0.2}
         )},
        fn -> Process.sleep(10_000) end
      ]

      :ok = start_vehicle(name, events_into_charging(me, now_ts, tail))

      assert_receive {:insert_charge, cproc, %{charge_energy_added: 0.1}}, 800
      assert_receive :charging_reached, 800

      cs = %TeslaMate.FleetTelemetry.ChargeStream{
        time: DateTime.utc_now(),
        charging_state: "DetailedChargeStateStopped",
        charger_power: 0,
        charge_energy_added: 6.0,
        battery_level: 60,
        rated_battery_range_km: 120.0,
        ideal_battery_range_km: 120.0
      }

      send(name, {:stream_charge, cs})

      # letzter Kurvenpunkt akkuseitig + prompter Abschluss (nicht +interval)
      assert_receive {:insert_charge, ^cproc, %{charge_energy_added: 6.0}}, 800
      assert_receive {:complete_charging_process, ^cproc}, 800
      # Uebergang -> :start -> frischer Poll -> :online
      assert_receive {:start_state, _car, :online, _}, 1500
    end

    test "{:stream_charge, :fleet_streaming} ist ein reiner Freshness-Ping (kein insert)",
         %{test: name} do
      me = self()
      now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      :ok = start_vehicle(name, events_into_charging(me, now_ts, [fn -> Process.sleep(10_000) end]))

      assert_receive {:insert_charge, _cproc, %{charge_energy_added: 0.1}}, 800
      assert_receive :charging_reached, 800

      send(name, {:stream_charge, :fleet_streaming})
      refute_receive {:insert_charge, _, _}, 200
      refute_receive {:complete_charging_process, _}, 50
    end

    test "Lebenszyklus: ChargeStreamProvider bei :charging-Eintritt gestartet, bei Ende gestoppt",
         %{test: name} do
      System.put_env("FLEET_TELEMETRY_FEED_CHARGING", "true")
      System.put_env("FLEET_TELEMETRY_VIN", "1000")

      on_exit(fn ->
        System.delete_env("FLEET_TELEMETRY_FEED_CHARGING")
        System.delete_env("FLEET_TELEMETRY_VIN")
      end)

      me = self()
      now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)

      tail = [
        {:ok,
         online_event(now_ts + 9,
           drive_state: %{timestamp: now_ts + 9, latitude: 0.2, longitude: 0.2}
         )},
        fn -> Process.sleep(10_000) end
      ]

      :ok = start_vehicle(name, events_into_charging(me, now_ts, tail))

      assert_receive :charging_reached, 800

      # Provider laeuft, charge_stream_pid ist gesetzt
      {{:charging, _cproc}, data} = :sys.get_state(name)
      assert is_pid(data.charge_stream_pid)
      assert Process.alive?(data.charge_stream_pid)
      pid = data.charge_stream_pid

      # feed-getriebenes Ende -> Provider gestoppt + pid aus Data
      send(name, {:stream_charge,
       %TeslaMate.FleetTelemetry.ChargeStream{
         time: DateTime.utc_now(),
         charging_state: "DetailedChargeStateStopped",
         charge_energy_added: 6.0,
         battery_level: 60
       }})

      assert_receive {:complete_charging_process, _}, 800
      assert_receive {:start_state, _car, :online, _}, 1500

      {_state, data2} = :sys.get_state(name)
      assert data2.charge_stream_pid == nil

      # Provider gestoppt (kurze Grace-Periode fuer den async Tortoise-Abbau).
      assert Enum.any?(1..20, fn _ ->
               if Process.alive?(pid), do: Process.sleep(10)
               not Process.alive?(pid)
             end)
    end
  end
end
