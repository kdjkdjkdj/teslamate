defmodule TeslaMate.FleetTelemetry.ChargeStream do
  @moduledoc """
  Virtueller Lade-Schnappschuss aus dem Fleet-Telemetry-Feed (analog
  `TeslaApi.Stream.Data` fuer den Fahr-Feed). Traegt die Ladefelder, die
  `merge_charge/3` in das letzte volle Poll-`%Vehicle{}` mischt, bevor der
  bestehende `insert_charge` einen Kurvenpunkt schreibt.

  Ranges sind bereits in km (mi->km konvertiert im Mapper), Power ist der native
  kW-Wert (DC bevorzugt, sonst AC), `charge_energy_added` akkuseitig.
  """

  defstruct time: nil,
            charging_state: nil,
            charger_power: nil,
            charger_voltage: nil,
            charger_actual_current: nil,
            charger_phases: nil,
            charge_energy_added: nil,
            battery_level: nil,
            usable_battery_level: nil,
            ideal_battery_range_km: nil,
            rated_battery_range_km: nil,
            fast_charger_present: nil,
            fast_charger_type: nil
end
