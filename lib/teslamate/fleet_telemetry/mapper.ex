defmodule TeslaMate.FleetTelemetry.Mapper do
  @moduledoc """
  Pure Mapping von rollendem Fleet-Telemetry-Feldzustand auf
  ShadowPosition-Attrs. Keine Seiteneffekte, keine DB.
  """

  alias TeslaMate.FleetTelemetry.ChargeStream

  @mi_to_km 1.609344

  # Wirkungsgrad des Onboard-Chargers (AC -> DC), fuer die akkuseitige Energie bei
  # AC-Ladung. Gemessen 2026-08-05 an Ladung #390 (92 min, 11 kW dreiphasig):
  # DCChargingEnergyIn / ACChargingEnergyIn = 0,955; gegen den Wallbox-Zaehler
  # (16,404 kWh netzseitig) = 0,946.
  #
  # Bewusst eine Konstante und kein Konfigwert - ein Wert, den man im Diff sieht, ist
  # besser als einer, der in einer .env verschwindet. Und bewusst eine Zahl statt einer
  # Kennlinie: der Wirkungsgrad ist last- und temperaturabhaengig, belegt ist bisher nur
  # der Punkt "11 kW dreiphasig". Eine Kennlinie erst, wenn Messungen bei anderen
  # Leistungen vorliegen (einphasig, gedrosselt durch den dynamischen Stromtarif).
  @onboard_charger_efficiency 0.95

  @doc "Power-Proxy: -(V*I)/1000 in kW (Integer). Vorzeichen gedreht."
  def power_kw(voltage, current) when is_number(voltage) and is_number(current) do
    round(-(voltage * current) / 1000)
  end

  def power_kw(_, _), do: nil

  def miles_to_km(mi) when is_number(mi), do: mi * @mi_to_km
  def miles_to_km(_), do: nil

  def to_attrs(fields, car_id, date) when is_map(fields) do
    loc = Map.get(fields, "Location")

    %{
      car_id: car_id,
      date: date,
      latitude: loc && Map.get(loc, "latitude"),
      longitude: loc && Map.get(loc, "longitude"),
      elevation: nil,
      speed: fields |> Map.get("VehicleSpeed") |> mph_to_kmh() |> round_or_nil(),
      power: power_kw(Map.get(fields, "PackVoltage"), Map.get(fields, "PackCurrent")),
      odometer: fields |> Map.get("Odometer") |> miles_to_km(),
      battery_level: fields |> Map.get("BatteryLevel") |> round_or_nil(),
      usable_battery_level: fields |> Map.get("Soc") |> round_or_nil(),
      rated_battery_range_km: fields |> Map.get("RatedRange") |> miles_to_km(),
      ideal_battery_range_km: fields |> Map.get("IdealBatteryRange") |> miles_to_km(),
      est_battery_range_km: fields |> Map.get("EstBatteryRange") |> miles_to_km(),
      outside_temp: Map.get(fields, "OutsideTemp"),
      inside_temp: Map.get(fields, "InsideTemp"),
      is_climate_on: Map.get(fields, "HvacACEnabled"),
      is_front_defroster_on: defrost_on?(Map.get(fields, "DefrostMode")),
      is_rear_defroster_on: nil,
      fan_status: fields |> Map.get("HvacFanStatus") |> round_or_nil(),
      battery_heater_on: Map.get(fields, "BatteryHeaterOn"),
      tpms_pressure_fl: Map.get(fields, "TpmsPressureFl"),
      tpms_pressure_fr: Map.get(fields, "TpmsPressureFr"),
      tpms_pressure_rl: Map.get(fields, "TpmsPressureRl"),
      tpms_pressure_rr: Map.get(fields, "TpmsPressureRr"),
      power_source: "packvi_proxy"
    }
  end


  alias TeslaApi.Stream

  def gear_to_shift_state("ShiftStateD"), do: "D"
  def gear_to_shift_state("ShiftStateR"), do: "R"
  def gear_to_shift_state("ShiftStateN"), do: "N"
  def gear_to_shift_state("ShiftStateP"), do: "P"
  def gear_to_shift_state(_), do: nil

  @doc "Invers zu gear_to_shift_state: TeslaMate-Gang -> Fleet-Rohwert (fuer Feed-Seed)."
  def shift_state_to_gear("D"), do: "ShiftStateD"
  def shift_state_to_gear("R"), do: "ShiftStateR"
  def shift_state_to_gear("N"), do: "ShiftStateN"
  def shift_state_to_gear("P"), do: "ShiftStateP"
  def shift_state_to_gear(_), do: nil

  @doc "Fleet-Rohfelder -> %Stream.Data{} (imperial passthrough; create_position konvertiert)."
  def to_stream_data(fields, %DateTime{} = now) when is_map(fields) do
    loc = Map.get(fields, "Location")

    %Stream.Data{
      time: now,
      est_lat: loc && Map.get(loc, "latitude"),
      est_lng: loc && Map.get(loc, "longitude"),
      shift_state: gear_to_shift_state(Map.get(fields, "Gear")),
      speed: Map.get(fields, "VehicleSpeed"),
      odometer: Map.get(fields, "Odometer"),
      soc: fields |> Map.get("Soc") |> round_or_nil(),
      power: power_kw(Map.get(fields, "PackVoltage"), Map.get(fields, "PackCurrent")),
      elevation: nil
    }
  end

  defp mph_to_kmh(v) when is_number(v), do: v * @mi_to_km
  defp mph_to_kmh(_), do: nil

  defp round_or_nil(v) when is_number(v), do: round(v)
  defp round_or_nil(_), do: nil

  defp defrost_on?(nil), do: nil
  defp defrost_on?("DefrostModeOff"), do: false
  defp defrost_on?(mode) when is_binary(mode), do: true
  defp defrost_on?(_), do: nil

  # === Laden (Charge-Shadow, Stufe 1) ===

  @doc """
  Normalisiert den DetailedChargeState-Rohwert: strippt einen etwaigen
  Enum-Prefix `DetailedChargeState` und downcased. Robust gegen beide
  Schreibweisen (`"Charging"` wie `"DetailedChargeStateCharging"`).
  """
  def charge_phase(raw) when is_binary(raw) do
    raw |> String.replace_prefix("DetailedChargeState", "") |> String.downcase()
  end

  def charge_phase(_), do: nil

  @doc "True, wenn der DetailedChargeState-Rohwert eine Lade-Lifecycle-Phase ist (starting/charging/complete/stopped)."
  def charging_lifecycle?(raw) do
    charge_phase(raw) in ["starting", "charging", "complete", "stopped"]
  end

  @doc """
  Invers (grob) zu charge_phase: TeslaMate-`charging_state` -> Fleet-`DetailedChargeState`-Rohwert.
  Fuer den Feed-Seed (seed_fleet_charge_state), damit die zuletzt gepollte Phase in den
  ChargeStreamProvider-FieldState zurueckfliesst und die Stopped-Kante nicht verpasst wird.
  Whitelist (kein blindes Prefixen), sonst nil -> kein Garbage-Seed.
  """
  def charge_state_to_detailed("Starting"), do: "DetailedChargeStateStarting"
  def charge_state_to_detailed("Charging"), do: "DetailedChargeStateCharging"
  def charge_state_to_detailed("Complete"), do: "DetailedChargeStateComplete"
  def charge_state_to_detailed("Stopped"), do: "DetailedChargeStateStopped"
  def charge_state_to_detailed("NoPower"), do: "DetailedChargeStateNoPower"
  def charge_state_to_detailed("Disconnected"), do: "DetailedChargeStateDisconnected"
  def charge_state_to_detailed(_), do: nil

  @doc "Fleet-Rohfelder -> ShadowCharge-Attrs. Pure, keine Seiteneffekte, keine DB."
  def to_charge_attrs(fields, car_id, date) when is_map(fields) do
    dc_power = Map.get(fields, "DCChargingPower")
    ac_power = Map.get(fields, "ACChargingPower")
    {source, power} = charge_source_power(dc_power, ac_power)

    %{
      car_id: car_id,
      date: date,
      charging_state: Map.get(fields, "DetailedChargeState"),
      charge_source: source,
      charger_power: round_or_nil(power),
      charger_voltage: fields |> Map.get("ChargerVoltage") |> round_or_nil(),
      charger_actual_current: fields |> Map.get("ChargeAmps") |> round_or_nil(),
      charger_phases: fields |> Map.get("ChargerPhases") |> round_or_nil(),
      charge_energy_added: charge_energy_added(fields),
      battery_level: fields |> Map.get("BatteryLevel") |> round_or_nil(),
      usable_battery_level: fields |> Map.get("Soc") |> round_or_nil(),
      ideal_battery_range_km: fields |> Map.get("IdealBatteryRange") |> miles_to_km(),
      rated_battery_range_km: fields |> Map.get("RatedRange") |> miles_to_km(),
      fast_charger_present: Map.get(fields, "FastChargerPresent"),
      fast_charger_type: Map.get(fields, "FastChargerType")
    }
  end

  @doc """
  Fleet-Rohfelder -> `%ChargeStream{}` (Live-Feed-Snapshot fuer die :charging-Verdichtung).
  Teilt die Feldkenntnis + Konversionen mit `to_charge_attrs/3` (dieselben privaten Helfer
  `charge_source_power`/`charge_energy_added`, kein Copy-Paste). Ranges bereits in km,
  Power nativ (DC bevorzugt), Energie akkuseitig.
  """
  def to_charge_stream(fields, %DateTime{} = now) when is_map(fields) do
    dc_power = Map.get(fields, "DCChargingPower")
    ac_power = Map.get(fields, "ACChargingPower")
    {_source, power} = charge_source_power(dc_power, ac_power)

    %ChargeStream{
      time: now,
      charging_state: Map.get(fields, "DetailedChargeState"),
      charger_power: round_or_nil(power),
      charger_voltage: fields |> Map.get("ChargerVoltage") |> round_or_nil(),
      charger_actual_current: fields |> Map.get("ChargeAmps") |> round_or_nil(),
      charger_phases: fields |> Map.get("ChargerPhases") |> round_or_nil(),
      charge_energy_added: charge_energy_added(fields),
      battery_level: fields |> Map.get("BatteryLevel") |> round_or_nil(),
      usable_battery_level: fields |> Map.get("Soc") |> round_or_nil(),
      ideal_battery_range_km: fields |> Map.get("IdealBatteryRange") |> miles_to_km(),
      rated_battery_range_km: fields |> Map.get("RatedRange") |> miles_to_km(),
      fast_charger_present: Map.get(fields, "FastChargerPresent"),
      fast_charger_type: Map.get(fields, "FastChargerType")
    }
  end

  # DC bevorzugt (Supercharger), sonst AC (Heimladen). Nativer kW-Wert, kein V*I-Proxy.
  defp charge_source_power(dc, ac) do
    cond do
      is_number(dc) and dc > 0 -> {"dc", dc}
      is_number(ac) and ac > 0 -> {"ac", ac}
      is_number(dc) -> {"dc", dc}
      is_number(ac) -> {"ac", ac}
      true -> {nil, nil}
    end
  end

  # charge_energy_added ist akkuseitig zugefuehrte Energie (wie TeslaMate), damit die
  # Gegenrechnung mit dem netzseitigen charge_energy_used eine Effizienz ergibt. Die QUELLE
  # haengt an der Ladeart, nicht daran, welches Feld gerade anliegt:
  #
  #   DC (Supercharger): DCChargingEnergyIn - nativer, akkuseitiger Zaehler.
  #   AC (Heimladen):    ACChargingEnergyIn (netzseitig) * @onboard_charger_efficiency.
  #
  # ⚠️ Warum bei AC NICHT der DC-Zaehler, obwohl er die richtige Messstelle hat
  # (Messreihe 2026-08-05, Ladungen #383 und #390, 187 Feed-Samples):
  #
  #   1. Er ist auf 0,02 kWh quantisiert und haengt schwankend 0 ... 0,11 kWh zurueck.
  #      Die Sitzungssumme ist `letzter - erster` (log.ex), es landet also die DIFFERENZ
  #      zweier Rueckstaende im Ergebnis - ein ABSOLUTER Fehler, unabhaengig von der
  #      Ladungsgroesse. Bei #390 (15,52 kWh) sind das 0,7 %, bei #384 (0,30 kWh) 37 %.
  #   2. Er ist nicht monoton: im Stand faellt er (03.08.: 19,34 -> 19,24 bei 0 kW).
  #   3. Er wird zwischen Sitzungen uebernommen statt zurueckgesetzt. #383 erbte den
  #      Rueckstand der Vorsitzung und holte ihn waehrend der Ladung auf: gemeldet
  #      2,40 kWh gegen 2,0182 kWh Netzbezug am Wallbox-Zaehler - akkuseitig ueber
  #      netzseitig, also physikalisch unmoeglich.
  #
  # ACChargingEnergyIn deckt sich dagegen auf JEDEM der 187 Samples auf < 1 % mit
  # ACChargingPower und ist monoton. Uebernahme zwischen Sitzungen schadet dort nicht:
  # auf einem driftfreien Zaehler ist `letzter - erster` exakt, egal wo er startet.
  #
  # ⚠️ Kein stiller Rueckfall mehr auf das jeweils andere Feld. Die zwei Zaehler haben
  # verschiedene Skalen und werden zu verschiedenen Zeitpunkten zurueckgesetzt; der alte
  # Fallback mischte sie in EINE Spalte (belegt: 21,64 -> 0 innerhalb von 1,3 ms).
  # Ist die Ladeart unbekannt, ist die Antwort nil = "nicht geliefert" - nie ein
  # Ersatzwert von einer anderen Messstelle. Die Kurvenzeile faellt dann im Changeset
  # durch (`charge_energy_added: can't be blank`), und `erster`/`letzter` greifen die
  # naechste Zeile mit echtem Messwert - genau das ist gewollt.
  defp charge_energy_added(fields) do
    case charge_kind(fields) do
      :dc -> fields |> Map.get("DCChargingEnergyIn") |> number_or_nil()
      :ac -> fields |> Map.get("ACChargingEnergyIn") |> number_or_nil() |> scale(@onboard_charger_efficiency)
      :unknown -> nil
    end
  end

  # Ladeart der laufenden Sitzung.
  #
  # Bewusst NICHT aus charge_source_power/2 abgeleitet: dessen letzte cond-Zweige greifen
  # ohne `> 0` und liefern bei 0 kW "dc". Null kW sind aber genau die Rand-Zeilen einer
  # Sitzung - und die greift log.ex als `erster`/`letzter` auf. Ein dort falscher
  # Klassifikator wuerde die zwei Zaehler erneut mischen, nur an anderer Stelle.
  #
  # FastChargerPresent ist die belastbarste Quelle (eine Aussage ueber die Sitzung, nicht
  # ueber den Augenblick), taugt aber nicht allein: Tesla sendet Felder nur bei AENDERUNG,
  # `interval_seconds` ist eine Obergrenze und keine Zusage. Gemessen 2026-08-05 kam es in
  # 100 Minuten genau einmal (t+16 s, mit dem Reconnect-Snapshot). Zwei AC-Ladungen
  # hintereinander ohne Schlaf dazwischen bekommen keinen neuen Snapshot -> das Feld
  # erreicht den je Sitzung frischen Provider-FieldState nie. Deshalb der Leistungs-
  # Rueckfall, der greift, solange ueberhaupt Leistung fliesst.
  defp charge_kind(fields) do
    dc_power = Map.get(fields, "DCChargingPower")
    ac_power = Map.get(fields, "ACChargingPower")

    cond do
      Map.get(fields, "FastChargerPresent") == true -> :dc
      Map.get(fields, "FastChargerPresent") == false -> :ac
      is_number(dc_power) and dc_power > 0 -> :dc
      is_number(ac_power) and ac_power > 0 -> :ac
      true -> :unknown
    end
  end

  defp number_or_nil(v) when is_number(v), do: v
  defp number_or_nil(_), do: nil

  defp scale(nil, _factor), do: nil
  defp scale(v, factor), do: v * factor
end
