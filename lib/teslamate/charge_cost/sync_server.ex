defmodule TeslaMate.ChargeCost.SyncServer do
  @moduledoc """
  Periodischer Sweep, der offene Supercharger-Ladungen mit echten Fleet-Kosten
  befuellt. Liest die Einstellungen (`suc_cost_basis`, `suc_sync_interval_hours`,
  `suc_giveup_window_days`) bei jedem Tick frisch -> live-reaktiv auf Settings-Aenderungen.

  Zwei Betriebsmodi steuern die Pagination-Seitengroesse (Kosten-Hebel, da pro
  Datensatz abgerechnet wird):

    * `:periodic` — regulaerer Tick, groessere Seite (`@periodic_page_size`)
    * `:nudge`    — nach Lade-Ende angestossen, minimale Seite (`@nudge_page_size`),
                    da nur die eine frische Ladung gesucht wird.

  Nach jedem Lauf faellt der Modus auf `:periodic` zurueck. `nudge/0` stoesst einen
  sofortigen (entprellten) Lauf an.
  """

  use GenServer
  require Logger

  alias TeslaMate.{Settings, Log}
  alias TeslaMate.ChargeCost.Sync

  defmodule State do
    defstruct timer: nil, mode: :periodic
  end

  # Erster Lauf kurz nach Boot; Nudge entprellt auf wenige Sekunden.
  @initial_delay_ms 5_000
  @nudge_delay_ms 2_000

  # Seitengroessen je Modus. Nudge sucht nur die juengste Ladung -> Seite 1 deckt sie.
  @nudge_page_size 2
  @periodic_page_size 10

  # API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Stoesst einen sofortigen, entprellten Sync an (fehlertolerant)."
  def nudge do
    GenServer.cast(__MODULE__, :nudge)
  end

  # Server

  @impl true
  def init(_opts) do
    {:ok, schedule(%State{}, @initial_delay_ms)}
  end

  @impl true
  def handle_info(:tick, %State{mode: mode} = state) do
    page_size = if mode == :nudge, do: @nudge_page_size, else: @periodic_page_size
    interval_hours = run_sync(page_size)
    # Modus nach dem Lauf zuruecksetzen, naechster regulaerer Tick.
    {:noreply, schedule(%State{state | mode: :periodic}, interval_hours * 3600 * 1000)}
  end

  @impl true
  def handle_cast(:nudge, %State{} = state) do
    {:noreply, schedule(%State{state | mode: :nudge}, @nudge_delay_ms)}
  end

  # Fuehrt den Sync fuer alle Autos aus, gibt das (settings-gesteuerte) Intervall in Stunden zurueck.
  defp run_sync(page_size) do
    s = Settings.get_global_settings!()

    for car <- Log.list_cars() do
      case Sync.run(car,
             basis: s.suc_cost_basis,
             window_days: s.suc_giveup_window_days,
             page_size: page_size
           ) do
        {:ok, %{matched: matched} = res} when matched > 0 ->
          Logger.info("SuC cost sync #{car.vin}: #{inspect(res)}")

        {:ok, _res} ->
          :ok

        {:error, reason} ->
          Logger.warning("SuC cost sync failed for #{car.vin}: #{inspect(reason)}")
      end
    end

    s.suc_sync_interval_hours
  rescue
    e ->
      Logger.error("SuC cost sync crashed: #{Exception.message(e)}")
      # Fallback-Intervall, falls Settings nicht lesbar sind
      6
  end

  # Storniert einen evtl. ausstehenden Timer und plant den naechsten Tick.
  defp schedule(%State{timer: timer} = state, delay_ms) do
    if is_reference(timer), do: Process.cancel_timer(timer)
    %State{state | timer: Process.send_after(self(), :tick, delay_ms)}
  end
end
