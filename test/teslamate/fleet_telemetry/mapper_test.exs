defmodule TeslaMate.FleetTelemetry.MapperTest do
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.Mapper

  test "power proxy drehs Vorzeichen: Laden negativ, Fahren positiv" do
    # 23.06.-Realwerte Laden: 391.31 V * 138.8 A -> +54 kW Pack-Input -> -54 nach Drehung
    assert Mapper.power_kw(391.31, 138.8) == -54
    # Fahren/Entladen: 391 V * -28.8 A -> -11 kW -> +11 nach Drehung
    assert Mapper.power_kw(391.0, -28.8) == 11
    assert Mapper.power_kw(nil, 138.8) == nil
    assert Mapper.power_kw(391.0, nil) == nil
  end

  test "miles_to_km" do
    assert_in_delta Mapper.miles_to_km(189.33), 304.66, 0.1
    assert Mapper.miles_to_km(nil) == nil
  end

  test "to_attrs mappt vollen Feldzustand auf Schatten-Spalten" do
    fields = %{
      "Location" => %{"latitude" => 48.396021, "longitude" => 10.860954},
      "VehicleSpeed" => 47.22,
      "PackVoltage" => 391.31,
      "PackCurrent" => 138.8,
      "Odometer" => 62547.4,
      "BatteryLevel" => 64.84,
      "Soc" => 64.0,
      "RatedRange" => 189.33,
      "OutsideTemp" => 28.5,
      "BatteryHeaterOn" => true,
      "TpmsPressureFl" => 3.4
    }

    attrs = Mapper.to_attrs(fields, 1, ~U[2026-06-23 10:08:24.000000Z])

    assert attrs.car_id == 1
    assert attrs.latitude == 48.396021
    assert attrs.longitude == 10.860954
    assert attrs.power == -54
    assert attrs.battery_level == 65
    assert attrs.usable_battery_level == 64
    assert attrs.battery_heater_on == true
    assert attrs.speed == 76
    assert attrs.power_source == "packvi_proxy"
    # Einheiten-Annahme Meilen (in Task 5 zu kalibrieren):
    assert_in_delta attrs.rated_battery_range_km, 304.66, 0.1
  end

  test "to_attrs toleriert fehlende Felder (nil statt Crash)" do
    attrs = Mapper.to_attrs(%{}, 1, ~U[2026-06-23 10:08:24.000000Z])
    assert attrs.car_id == 1
    assert attrs.latitude == nil
    assert attrs.power == nil
    assert attrs.power_source == "packvi_proxy"
  end

  describe "to_stream_data/2 (Live-Feed)" do
    test "mappt Fleet-Felder roh (imperial) in Stream.Data" do
      now = ~U[2026-06-25 10:00:00Z]
      fields = %{
        "Location" => %{"latitude" => 48.39, "longitude" => 10.86},
        "Gear" => "ShiftStateD",
        "VehicleSpeed" => 42.0,
        "Odometer" => 100_671.0,
        "Soc" => 74.0,
        "PackVoltage" => 391.31,
        "PackCurrent" => -28.8
      }

      sd = TeslaMate.FleetTelemetry.Mapper.to_stream_data(fields, now)
      assert sd.__struct__ == TeslaApi.Stream.Data
      assert sd.time == now
      assert sd.est_lat == 48.39
      assert sd.est_lng == 10.86
      assert sd.shift_state == "D"
      assert sd.speed == 42.0
      assert sd.odometer == 100_671.0
      assert sd.soc == 74
      assert sd.power == 11
    end

    test "gear_to_shift_state deckt alle Werte + null ab" do
      m = TeslaMate.FleetTelemetry.Mapper
      assert m.gear_to_shift_state("ShiftStateD") == "D"
      assert m.gear_to_shift_state("ShiftStateR") == "R"
      assert m.gear_to_shift_state("ShiftStateN") == "N"
      assert m.gear_to_shift_state("ShiftStateP") == "P"
      assert m.gear_to_shift_state(nil) == nil
      assert m.gear_to_shift_state("Quatsch") == nil
    end

    test "shift_state_to_gear ist invers zu gear_to_shift_state (fuer Feed-Seed)" do
      m = TeslaMate.FleetTelemetry.Mapper
      assert m.shift_state_to_gear("D") == "ShiftStateD"
      assert m.shift_state_to_gear("R") == "ShiftStateR"
      assert m.shift_state_to_gear("N") == "ShiftStateN"
      assert m.shift_state_to_gear("P") == "ShiftStateP"
      assert m.shift_state_to_gear(nil) == nil
      assert m.shift_state_to_gear("Quatsch") == nil
    end

    test "fehlende Location -> est_lat/est_lng nil, kein Crash" do
      sd = TeslaMate.FleetTelemetry.Mapper.to_stream_data(%{"Gear" => "ShiftStateP"}, ~U[2026-06-25 10:00:00Z])
      assert sd.est_lat == nil
      assert sd.shift_state == "P"
    end
  end

  describe "to_charge_attrs/3 (Charge-Shadow)" do
    test "DC-Ladung (Supercharger): natives DCChargingPower, source dc, Energie akkuseitig (DC)" do
      fields = %{
        "DetailedChargeState" => "DetailedChargeStateCharging",
        "DCChargingPower" => 66.8,
        "DCChargingEnergyIn" => 12.5,
        "ACChargingEnergyIn" => 0.0,
        "ChargerVoltage" => 391.0,
        "ChargeAmps" => 138.0,
        "ChargerPhases" => 1,
        "BatteryLevel" => 64.6,
        "Soc" => 63.0,
        "RatedRange" => 189.33,
        "FastChargerPresent" => true,
        "FastChargerType" => "Tesla"
      }

      attrs = Mapper.to_charge_attrs(fields, 1, ~U[2026-06-23 10:08:24.000000Z])

      assert attrs.car_id == 1
      assert attrs.charging_state == "DetailedChargeStateCharging"
      assert attrs.charge_source == "dc"
      assert attrs.charger_power == 67
      assert attrs.charger_voltage == 391
      assert attrs.charger_actual_current == 138
      assert attrs.charger_phases == 1
      assert attrs.charge_energy_added == 12.5
      assert attrs.battery_level == 65
      assert attrs.usable_battery_level == 63
      assert attrs.fast_charger_present == true
      assert attrs.fast_charger_type == "Tesla"
      assert_in_delta attrs.rated_battery_range_km, 304.66, 0.1
    end

    test "AC-Ladung (Heim): natives ACChargingPower, source ac" do
      fields = %{
        "DetailedChargeState" => "DetailedChargeStateCharging",
        "ACChargingPower" => 11.0,
        "ACChargingEnergyIn" => 4.2,
        "ChargerVoltage" => 230.0,
        "ChargeAmps" => 16.0,
        "ChargerPhases" => 3
      }

      attrs = Mapper.to_charge_attrs(fields, 1, ~U[2026-06-23 10:08:24.000000Z])

      assert attrs.charge_source == "ac"
      assert attrs.charger_power == 11
      assert attrs.charger_phases == 3
      # AC-Sitzung -> netzseitiger Zaehler * Wirkungsgrad
      assert_in_delta attrs.charge_energy_added, 4.2 * 0.95, 0.0001
    end

    test "AC-Ladung mit beiden Energiefeldern: Quelle ist AC*eta, NICHT der DC-Zaehler" do
      # Reale Heim-AC-Ladung: der Onboard-Charger wandelt AC->DC. ACChargingEnergyIn =
      # netzseitig (vor dem Wandler), DCChargingEnergyIn = akkuseitig (nach dem Wandler).
      # Beide sind DIESELBE Energie an zwei Messpunkten -> nie addieren.
      #
      # Bis 2026-08-05 nahm der Mapper hier den DC-Wert (die richtige Messstelle). Die
      # Messreihe an #383/#390 hat ihn verworfen: quantisiert auf 0,02 kWh, schwankender
      # Rueckstand 0 ... 0,11 kWh, nicht monoton, Uebernahme zwischen Sitzungen. Bei #383
      # ergab das 2,40 kWh gegen 2,0182 kWh Netzbezug - akkuseitig ueber netzseitig.
      fields = %{
        "DetailedChargeState" => "DetailedChargeStateCharging",
        "ACChargingPower" => 11.0,
        "ACChargingEnergyIn" => 26.9,
        "DCChargingEnergyIn" => 24.8,
        "ChargerVoltage" => 224.0,
        "ChargeAmps" => 16.0
      }

      attrs = Mapper.to_charge_attrs(fields, 1, ~U[2026-07-12 10:18:56.000000Z])

      assert attrs.charge_source == "ac"
      assert_in_delta attrs.charge_energy_added, 26.9 * 0.95, 0.0001
      refute attrs.charge_energy_added == 24.8
    end

    test "nil-safe: fehlende Felder -> nil, kein Raten der Ladeart" do
      attrs = Mapper.to_charge_attrs(%{}, 1, ~U[2026-06-23 10:08:24.000000Z])
      assert attrs.car_id == 1
      assert attrs.charger_power == nil
      assert attrs.charge_source == nil
      assert attrs.charge_energy_added == nil
      assert attrs.charging_state == nil

      # Energiefeld ohne jede Ladeart-Evidenz (keine Leistung, kein FastChargerPresent):
      # Ladeart unbekannt -> nil. Frueher kam hier der Rohwert heraus, egal aus welcher
      # Messstelle er stammte.
      dc = Mapper.to_charge_attrs(%{"DCChargingEnergyIn" => 7.0}, 1, ~U[2026-06-23 10:08:24.000000Z])
      assert dc.charge_energy_added == nil

      ac = Mapper.to_charge_attrs(%{"ACChargingEnergyIn" => 3.5}, 1, ~U[2026-06-23 10:08:24.000000Z])
      assert ac.charge_energy_added == nil
    end

    test "Ladeart: FastChargerPresent schlaegt die Leistung" do
      # Am Supercharger kann ACChargingPower als Altwert im gemergten Feldzustand kleben.
      # Die Sitzungsaussage gewinnt.
      dc =
        Mapper.to_charge_attrs(
          %{
            "FastChargerPresent" => true,
            "ACChargingPower" => 11.0,
            "DCChargingEnergyIn" => 30.0,
            "ACChargingEnergyIn" => 99.9
          },
          1,
          ~U[2026-08-04 13:20:00.000000Z]
        )

      assert dc.charge_energy_added == 30.0

      # Umgekehrt: FastChargerPresent false -> AC, auch wenn eine DC-Leistung mitlaeuft.
      ac =
        Mapper.to_charge_attrs(
          %{
            "FastChargerPresent" => false,
            "DCChargingPower" => 5.0,
            "DCChargingEnergyIn" => 99.9,
            "ACChargingEnergyIn" => 10.0
          },
          1,
          ~U[2026-08-05 11:00:00.000000Z]
        )

      assert_in_delta ac.charge_energy_added, 10.0 * 0.95, 0.0001
    end

    test "Ladeart: Leistungs-Rueckfall, wenn FastChargerPresent fehlt" do
      # Zwei AC-Ladungen hintereinander ohne Schlaf: kein Reconnect-Snapshot, also kein
      # FastChargerPresent im frischen Provider-FieldState. Ohne diesen Rueckfall fiele
      # die ganze Sitzung aus (jede Kurvenzeile ohne Energie -> Changeset verwirft sie).
      ac =
        Mapper.to_charge_attrs(
          %{"ACChargingPower" => 10.7, "ACChargingEnergyIn" => 4.0, "DCChargingEnergyIn" => 3.6},
          1,
          ~U[2026-08-05 11:00:00.000000Z]
        )

      assert_in_delta ac.charge_energy_added, 4.0 * 0.95, 0.0001

      # Am Supercharger vor dem Eintreffen von FastChargerPresent (bei #386 die ersten
      # drei Zeilen) traegt die DC-Leistung die Entscheidung.
      dc =
        Mapper.to_charge_attrs(
          %{"DCChargingPower" => 37.0, "DCChargingEnergyIn" => 8.0, "ACChargingEnergyIn" => 0.0},
          1,
          ~U[2026-08-04 13:13:00.000000Z]
        )

      assert dc.charge_energy_added == 8.0
    end

    test "Rand-Zeile bei 0 kW ohne Ladeart -> nil statt geratener Quelle" do
      # charge_source_power/2 liefert hier "dc" (cond-Zweig ohne `> 0`). Genau solche
      # Zeilen greift log.ex als `erster`/`letzter` auf - die Energie darf hier NICHT aus
      # einer geratenen Messstelle kommen. nil laesst den Changeset die Zeile verwerfen,
      # `erster` rueckt auf die naechste Zeile mit echtem Messwert.
      attrs =
        Mapper.to_charge_attrs(
          %{
            "DCChargingPower" => 0,
            "ACChargingPower" => 0,
            "DCChargingEnergyIn" => 19.24,
            "ACChargingEnergyIn" => 20.9
          },
          1,
          ~U[2026-08-03 17:00:52.000000Z]
        )

      assert attrs.charge_source == "dc"
      assert attrs.charge_energy_added == nil
    end

    test "kein stiller Rueckfall auf die andere Messstelle" do
      # AC-Sitzung, AC-Feld fehlt -> nil, NICHT der DC-Zaehler.
      ac =
        Mapper.to_charge_attrs(
          %{"FastChargerPresent" => false, "ACChargingPower" => 11.0, "DCChargingEnergyIn" => 24.8},
          1,
          ~U[2026-08-05 11:00:00.000000Z]
        )

      assert ac.charge_energy_added == nil

      # DC-Sitzung, DC-Feld fehlt -> nil, NICHT der AC-Zaehler.
      dc =
        Mapper.to_charge_attrs(
          %{"FastChargerPresent" => true, "DCChargingPower" => 37.0, "ACChargingEnergyIn" => 26.9},
          1,
          ~U[2026-08-04 13:20:00.000000Z]
        )

      assert dc.charge_energy_added == nil
    end

    test "charge_phase normalisiert beide Schreibweisen" do
      assert Mapper.charge_phase("DetailedChargeStateCharging") == "charging"
      assert Mapper.charge_phase("Charging") == "charging"
      assert Mapper.charge_phase("DetailedChargeStateComplete") == "complete"
      assert Mapper.charge_phase(nil) == nil
    end

    test "charging_lifecycle? erkennt Lifecycle-Phasen, nicht Idle/Disconnected" do
      assert Mapper.charging_lifecycle?("DetailedChargeStateStarting")
      assert Mapper.charging_lifecycle?("Charging")
      assert Mapper.charging_lifecycle?("DetailedChargeStateComplete")
      assert Mapper.charging_lifecycle?("DetailedChargeStateStopped")
      refute Mapper.charging_lifecycle?("DetailedChargeStateDisconnected")
      refute Mapper.charging_lifecycle?("DetailedChargeStateNoPower")
      refute Mapper.charging_lifecycle?(nil)
    end
  end

  describe "to_charge_stream/2 (Live-Feed Snapshot)" do
    test "to_charge_stream: AC-Heim, akkuseitige Energie, Stopped-Kante" do
      fields = %{
        "DetailedChargeState" => "DetailedChargeStateStopped",
        "ACChargingPower" => 11.0,
        "ACChargingEnergyIn" => 26.9,
        "DCChargingEnergyIn" => 24.8,
        "ChargerVoltage" => 224.0,
        "ChargeAmps" => 16.0,
        "ChargerPhases" => 2,
        "BatteryLevel" => 63.0,
        "RatedRange" => 185.0
      }

      cs = Mapper.to_charge_stream(fields, ~U[2026-07-12 12:18:56Z])

      assert cs.__struct__ == TeslaMate.FleetTelemetry.ChargeStream
      assert cs.time == ~U[2026-07-12 12:18:56Z]
      assert cs.charging_state == "DetailedChargeStateStopped"
      assert cs.charger_power == 11
      assert cs.charger_voltage == 224
      assert cs.charger_actual_current == 16
      assert cs.charger_phases == 2
      # AC-Sitzung (ACChargingPower > 0) -> netzseitiger Zaehler * Wirkungsgrad,
      # nicht der DC-Zaehler. Siehe to_charge_attrs/3-Test zur Begruendung.
      assert_in_delta cs.charge_energy_added, 26.9 * 0.95, 0.0001
      assert cs.battery_level == 63
      assert_in_delta cs.rated_battery_range_km, 297.7, 0.5
    end

    test "to_charge_stream: DC-Supercharger, natives DCChargingPower, source dc" do
      fields = %{
        "DetailedChargeState" => "DetailedChargeStateCharging",
        "DCChargingPower" => 66.8,
        "DCChargingEnergyIn" => 12.5,
        "ACChargingEnergyIn" => 0.0,
        "ChargerVoltage" => 391.0,
        "ChargeAmps" => 138.0,
        "ChargerPhases" => 1,
        "BatteryLevel" => 64.6,
        "Soc" => 63.0,
        "IdealBatteryRange" => 189.33,
        "RatedRange" => 189.33,
        "FastChargerPresent" => true,
        "FastChargerType" => "Tesla"
      }

      cs = Mapper.to_charge_stream(fields, ~U[2026-06-23 10:08:24Z])

      assert cs.charging_state == "DetailedChargeStateCharging"
      assert cs.charger_power == 67
      assert cs.charge_energy_added == 12.5
      assert cs.battery_level == 65
      assert cs.usable_battery_level == 63
      assert cs.fast_charger_present == true
      assert cs.fast_charger_type == "Tesla"
      assert_in_delta cs.ideal_battery_range_km, 304.66, 0.1
      assert_in_delta cs.rated_battery_range_km, 304.66, 0.1
    end

    test "to_charge_stream nil-safe: leere Felder -> nil, kein Crash" do
      cs = Mapper.to_charge_stream(%{}, ~U[2026-06-23 10:08:24Z])
      assert cs.time == ~U[2026-06-23 10:08:24Z]
      assert cs.charging_state == nil
      assert cs.charger_power == nil
      assert cs.charge_energy_added == nil
      assert cs.battery_level == nil
      assert cs.rated_battery_range_km == nil
    end
  end

  describe "charge_state_to_detailed/1 (Feed-Seed Invers-Mapping)" do
    test "mappt TeslaMate-charging_state auf den Fleet-DetailedChargeState-Rohwert" do
      assert Mapper.charge_state_to_detailed("Starting") == "DetailedChargeStateStarting"
      assert Mapper.charge_state_to_detailed("Charging") == "DetailedChargeStateCharging"
      assert Mapper.charge_state_to_detailed("Complete") == "DetailedChargeStateComplete"
      assert Mapper.charge_state_to_detailed("Stopped") == "DetailedChargeStateStopped"
      assert Mapper.charge_state_to_detailed("NoPower") == "DetailedChargeStateNoPower"
      assert Mapper.charge_state_to_detailed("Disconnected") == "DetailedChargeStateDisconnected"
    end

    test "unbekannt/null -> nil (kein Garbage-Seed)" do
      assert Mapper.charge_state_to_detailed(nil) == nil
      assert Mapper.charge_state_to_detailed("Quatsch") == nil
    end

    test "ist konsistent mit charge_phase (Round-trip ueber die Lifecycle-Phasen)" do
      for state <- ["Starting", "Charging", "Complete", "Stopped"] do
        assert Mapper.charge_phase(Mapper.charge_state_to_detailed(state)) ==
                 String.downcase(state)
      end
    end
  end
end
