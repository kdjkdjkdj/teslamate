defmodule TeslaMate.FleetTelemetry.ChargeBackfill.Reconstructor do
  @moduledoc """
  Rekonstruiert eine verpasste Ladesession als vollwertigen `charging_process`
  ueber die bestehenden `Log`-Funktionen -- exakt der manuell fuer cp 375
  durchgefuehrte Ablauf (start_charging_process -> insert_charge je Zeile ->
  complete_charging_process). Die `Log`-Aufrufe kommen ueber einen DI-Seam
  (`deps.log`), damit die Logik hermetisch testbar ist.
  """

  @doc """
  Mappt eine Shadow-Zeile auf `charges`-Attrs. `charge_energy_added` wird roh
  uebernommen -- der v2-Mapper liefert bereits den akkuseitigen Wert.
  """
  def to_charge_attrs(row) do
    %{
      date: row.date,
      battery_level: row.battery_level,
      usable_battery_level: row.usable_battery_level,
      charge_energy_added: row.charge_energy_added,
      charger_actual_current: row.charger_actual_current,
      charger_phases: row.charger_phases,
      charger_power: row.charger_power,
      charger_voltage: row.charger_voltage,
      ideal_battery_range_km: row.ideal_battery_range_km,
      rated_battery_range_km: row.rated_battery_range_km,
      conn_charge_cable: "IEC",
      fast_charger_present: false
    }
  end

  @doc """
  Legt aus `session` (Detector-Session) einen `charging_process` an, fuellt die
  `charges` und ruft `complete_charging_process`. `deps` = `%{log: %{...}}` mit
  den Funktionen `start_charging_process/3`, `insert_charge/2`,
  `complete_charging_process/1`. Gibt `{:ok, cproc}` zurueck.
  """
  def reconstruct(car, session, position_attrs, deps) do
    log = deps.log

    {:ok, cproc} = log.start_charging_process.(car, position_attrs, lookup_address: true)

    Enum.each(session.rows, fn row ->
      {:ok, _} = log.insert_charge.(cproc, to_charge_attrs(row))
    end)

    log.complete_charging_process.(cproc)
  end
end
