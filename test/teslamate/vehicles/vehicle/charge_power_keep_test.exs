defmodule TeslaMate.Vehicles.Vehicle.ChargePowerKeepTest do
  # Pure Unit-Tests fuer das Fortschreiben von charger_power im Feed-Merge.
  #
  # Hintergrund (gemessen 2026-08-04 an Ladung #384): der Feed liefert `ChargerPower` nur
  # onChange. Ein Kurvenpunkt ohne das Feld traegt nil, merge_charge/3 schrieb das
  # bedingungslos durch, insert_charge machte per `|| 0` eine harte 0 daraus - 34 von 36
  # Zeilen standen auf 0 kW, obwohl 11 A bei 220 V flossen. determine_phases leitet aus der
  # Leistung die Phasenzahl ab, landet im Toleranzband bei 0 Phasen, und
  # calculate_energy_used multipliziert jede Zeile mit 0 -> charge_energy_used = 0,00.
  #
  # Das Ergebnis ist gefaehrlicher als ein NULL, weil eine plausible 0,00 den Filter
  # `energy_used >= 0` passiert und als Zahl im Dashboard steht.
  use ExUnit.Case, async: true

  alias TeslaMate.Vehicles.Vehicle
  alias TeslaMate.FleetTelemetry.ChargeStream
  alias TeslaApi.Vehicle, as: V
  alias TeslaApi.Vehicle.State.Charge

  defp vehicle(power) do
    %V{
      charge_state: %Charge{
        charging_state: "Charging",
        charger_power: power,
        charger_voltage: 220,
        charger_actual_current: 11,
        charger_phases: 1,
        timestamp: 1000
      }
    }
  end

  defp cs(power, state \\ "DetailedChargeStateCharging") do
    %ChargeStream{time: ~U[2026-08-04 09:31:00Z], charging_state: state, charger_power: power}
  end

  describe "keep_power?: true (Kurvenzeile waehrend des Ladens)" do
    test "fehlende Leistung im Feed haelt den letzten bekannten Wert" do
      merged = Vehicle.merge_charge(vehicle(11), cs(nil), time: true, keep_power?: true)
      assert merged.charge_state.charger_power == 11
    end

    test "eine ausdrueckliche 0 aus dem Feed gewinnt trotzdem" do
      # keep/2 ersetzt nur nil. Eine echte Leistungsmeldung 0 kW (Ladepause, gedrosselt auf
      # 0 A) ist eine Aussage und darf nicht ueberschrieben werden.
      merged = Vehicle.merge_charge(vehicle(11), cs(0), time: true, keep_power?: true)
      assert merged.charge_state.charger_power == 0
    end

    test "ein neuer Wert gewinnt" do
      merged = Vehicle.merge_charge(vehicle(11), cs(7), time: true, keep_power?: true)
      assert merged.charge_state.charger_power == 7
    end

    test "ohne vorherigen Poll-Wert bleibt es bei nil" do
      merged = Vehicle.merge_charge(vehicle(nil), cs(nil), time: true, keep_power?: true)
      assert merged.charge_state.charger_power == nil
    end

    test "die uebrigen Felder verhalten sich unveraendert" do
      merged = Vehicle.merge_charge(vehicle(11), cs(nil), time: true, keep_power?: true)
      assert merged.charge_state.charger_voltage == 220
      assert merged.charge_state.charger_actual_current == 11
      assert merged.charge_state.charger_phases == 1
      assert merged.charge_state.charging_state == "DetailedChargeStateCharging"
    end
  end

  describe "ohne die Option (Schlusszeile und Altverhalten)" do
    test "am Ladeende faellt die Leistung wirklich auf 0 - hier wird NICHT fortgeschrieben" do
      # Genau deshalb ist das Fortschreiben an die Option gebunden: wuerde die Schlusszeile
      # die alten 11 kW behalten, ginge dieser Wert in die Integration des letzten Intervalls
      # ein und `charge_energy_used` waere zu GROSS statt zu klein - Fehler getauscht.
      merged =
        Vehicle.merge_charge(vehicle(11), cs(nil, "DetailedChargeStateStopped"), time: true)

      assert merged.charge_state.charger_power == nil
    end

    test "Default ist das bisherige Verhalten" do
      merged = Vehicle.merge_charge(vehicle(11), cs(nil), time: true)
      assert merged.charge_state.charger_power == nil
    end

    test "keep_power?: false ist ausdruecklich dasselbe" do
      merged = Vehicle.merge_charge(vehicle(11), cs(nil), time: true, keep_power?: false)
      assert merged.charge_state.charger_power == nil
    end
  end
end
