defmodule TeslaMate.FleetTelemetry.StreamProvider do
  @moduledoc """
  Live-Feed: abonniert Fleet-Telemetry-MQTT und sendet bei Location-Events ein
  %TeslaApi.Stream.Data{} an den Vehicle-FSM (receiver).

  Robustheit (Variante 1): Der Prozess beendet sich bei einem Stall NICHT mehr.
  Er bleibt subscribed und am Leben, sodass er den Feed automatisch wieder
  aufnimmt, sobald Telemetrie zurueckkommt (z.B. nach einem Warm-up-Fenster, in
  dem das Auto zwar "online", aber noch nicht pushend ist). Solange Daten fliessen,
  signalisiert er dem FSM mit `:fleet_streaming` die Aktivitaet (Freshness); bleibt
  der Strom > stall_ms aus, hoert das Signal auf -> der FSM faellt ueber den
  Freshness-Check auf normales Polling zurueck und schaltet bei Rueckkehr der Daten
  selbsttaetig wieder auf den dichten Fleet-Takt.

  Teardown / Reconnect-Sicherheit: Jede Instanz oeffnet ihre Tortoise-MQTT-
  Verbindung mit einer EINDEUTIGEN client_id und baut sie in `terminate/2` wieder
  ab. Ohne das ueberlebt die (verlinkte, nicht-trappende) Connection den
  :normal-Stop des Providers und blockiert beim naechsten connect_stream Tortoises
  Connection-Registry mit `{:error, {:already_started, _}}`. Der fruehere
  strenge `{:ok, _} = ...`-Match liess `init` dann mit einem MatchError abstuerzen
  und riss ueber den Link den Vehicle-FSM mit -> Crash-Schleife bei jedem Lade-/
  Online-Uebergang. Connect-Fehler werden jetzt tolerant behandelt (degraded statt
  Crash).

  Warm-up-Gate (`require_fields`, Eintraege duerfen Alternativlisten sein): Eine Session
  beginnt nicht mit allen Feldern -
  Fleet sendet on-change mit Mindestabstand, ein Payload traegt im Schnitt 48,5 von
  59 Feldern. Emittiert der Provider schon auf den ersten Trigger, entsteht eine
  halbleere Startzeile, die stromabwaerts Schaden anrichtet (Position ohne Odometer
  -> `drives.start_km` NULL -> `distance` NULL; Ladezeile ohne IdealBatteryRange ->
  von `insert_charge` verworfen). Der Gate haelt den Emit deshalb zurueck, bis die
  konfigurierten Pflichtfelder einmal da waren - danach nie wieder, weil FieldState
  sie forttraegt. Zwei Sicherungen gegen Verstummen: nach `warmup_ms` wird trotzdem
  emittiert, und `emit_always` laesst definierte Ereignisse (Lade-Ende) sofort durch.

  `require_hard` fuer Felder, deren Fehlen die Zeile nicht aermer, sondern UNGUELTIG
  macht (Ladezeile ohne Energie -> `charge_energy_added: can't be blank`). Sie werden
  vom `warmup_ms`-Timeout NICHT ueberbrueckt. Ohne diese Trennung emittiert der Timeout
  genau die halbleere Zeile, gegen die der Gate gebaut wurde - am 04.08.2026 im Feld
  belegt: `warm-up beendet ohne [...] - emittiere degraded`, eine Millisekunde spaeter
  `Invalid charge data`. `emit_always` bleibt bewusst auch fuer harte Felder eine
  Ausnahme: ein verworfenes Lade-ENDE (offener charging_process) waere schlimmer als
  eine verworfene Kurvenzeile.
  """
  use GenServer
  require Logger

  alias TeslaMate.FleetTelemetry.{FieldState, Mapper, Handler}
  alias Tortoise311.Transport

  @stall_ms 90_000
  @warmup_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def ingest(server, field, value) when is_binary(field) do
    GenServer.cast(server, {:ingest, field, value})
  end

  @doc "Verbindungswechsel vom MQTT-Handler melden (:up | :down | :terminating)."
  def mark_connection(server, status) when status in [:up, :down, :terminating] do
    GenServer.cast(server, {:connection, status})
  end

  @doc """
  Ist die MQTT-Verbindung dieses Providers offen?

  ⚠️ Bewusst konservativ: alles ausser einem klaren `true` heisst `false` - kein Prozess,
  tot, nie verbunden oder nicht antwortend. Der Aufrufer (Parkdrosselung in vehicle.ex)
  darf dann nicht drosseln, weil ihn niemand wecken wuerde.

  Der Timeout ist kurz und der Exit gefangen: ein haengender Provider darf den
  Vehicle-FSM weder blockieren noch mitreissen. Das ist der Unterschied zu
  `Process.alive?/1`, das bei einem lebenden, aber verbindungslosen Provider `true`
  sagt - genau die Luecke, gegen die diese Funktion gebaut ist (der Provider ueberlebt
  einen Stall absichtlich, siehe @moduledoc).
  """
  def connected?(server, timeout \\ 200)

  def connected?(pid, timeout) when is_pid(pid) do
    GenServer.call(pid, :connected?, timeout) == true
  catch
    :exit, _ -> false
  end

  def connected?(_server, _timeout), do: false

  def stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal), else: :ok
    :ok
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    st = %{
      car_id: Keyword.fetch!(opts, :car_id),
      vin: Keyword.fetch!(opts, :vin),
      receiver: Keyword.fetch!(opts, :receiver),
      state: FieldState.new(trigger_field: Keyword.get(opts, :trigger_field, "Location")),
      # map_fun mappt den getriggerten Feldzustand auf das emittierte Objekt. Default ist
      # der Fahr-Feed (%Stream.Data{}); der Charge-Feed injiziert &Mapper.to_charge_stream/2
      # und wird so ueber denselben Provider (client_id/terminate/Stall/connect) wiederverwendet.
      map_fun: Keyword.get(opts, :map_fun, &Mapper.to_stream_data/2),
      stall_ms: Keyword.get(opts, :stall_ms, @stall_ms),
      # Warm-up-Gate (siehe @moduledoc): Felder, die vor dem ERSTEN Emit dagewesen sein
      # muessen. Leer = Gate aus (Default, Verhalten unveraendert). Ein Eintrag darf eine
      # LISTE von Alternativen sein - dann genuegt eines davon (z.B. DC- ODER AC-Energie:
      # beide zu fordern waere nie erfuellbar, DC-Laden sendet kein AC-Feld).
      require_fields: Keyword.get(opts, :require_fields, []),
      # Harte Pflichtfelder (gleiche Form, Alternativlisten erlaubt): ihr Fehlen macht die
      # Zeile stromabwaerts ungueltig statt nur aermer -> kein Timeout-Bypass.
      require_hard: Keyword.get(opts, :require_hard, []),
      warmup_ms: Keyword.get(opts, :warmup_ms, @warmup_ms),
      # Ausnahme vom Gate: (field, value) -> true erzwingt den Emit auch im Warm-up.
      # Der Lade-Feed laesst so die Stopped/Complete-Kante immer durch.
      emit_always: Keyword.get(opts, :emit_always, fn _field, _value -> false end),
      # Nur fuer die Logzeilen: derselbe Provider bedient Fahr-, Lade- und Ladewaechter-Feed,
      # und "feeding live positions" waere fuer die letzten zwei irrefuehrend.
      label: Keyword.get(opts, :label, "FleetTelemetry stream"),
      warmup?: true,
      started_at: DateTime.utc_now(),
      streaming?: false,
      timer: nil,
      client_id: nil,
      # Erst ein ausdrueckliches :up des Handlers schaltet das auf true. Vor der ersten
      # Meldung gilt die Verbindung als geschlossen - die sichere Richtung.
      connected?: false
    }

    st =
      if Keyword.get(opts, :connect?, true) do
        %{st | client_id: connect(opts, st.vin)}
      else
        st
      end

    {:ok, arm_timer(st)}
  end

  @impl true
  def handle_cast({:connection, status}, st) do
    {:noreply, %{st | connected?: status == :up}}
  end

  def handle_cast({:ingest, field, value}, st) do
    now = DateTime.utc_now()
    fs = FieldState.put(st.state, field, value, now)
    st = %{st | state: fs}

    st =
      cond do
        not FieldState.trigger?(fs, field) ->
          st

        not emit?(st, fs, field, value, now) ->
          Logger.debug(
            "FleetTelemetry warm-up: emit zurueckgehalten, fehlt noch #{inspect(missing(st, fs))}"
          )

          st

        true ->
          if st.warmup? and missing(st, fs) != [] do
            # Der Grund gehoert in die Zeile. Die alte Fassung nannte immer "warm-up beendet"
            # und liess damit den Timeout als Ursache erscheinen, auch wenn in Wahrheit die
            # emit_always-Ausnahme gefeuert hatte. Am 04.08.2026 hat genau das eine
            # Fehlersuche in die falsche Richtung geschickt: der degradierte Emit kam 27,8 s
            # nach Provider-Start, das Fenster sind 60 s - es war nie der Timeout.
            grund =
              if st.emit_always.(field, value) do
                "Ausnahme emit_always"
              else
                "Timeout #{st.warmup_ms} ms"
              end

            Logger.info(
              "FleetTelemetry warm-up beendet ohne #{inspect(missing(st, fs))} - emittiere degraded (#{grund})"
            )
          end

          sd = st.map_fun.(FieldState.fields(fs), now)
          # Stream-Daten zuerst, dann das Freshness-Signal: so bleibt die
          # Objekt-Reihenfolge fuer den FSM eindeutig.
          safe_emit(st.receiver, sd)
          safe_emit(st.receiver, :fleet_streaming)

          if not st.streaming? do
            Logger.info("#{st.label} active - receiving live data")
          end

          arm_timer(%{st | streaming?: true, warmup?: false})
      end

    {:noreply, st}
  end

  @impl true
  def handle_call(:connected?, _from, st), do: {:reply, st.connected?, st}

  @impl true
  def handle_info(:stall, st) do
    if st.streaming? do
      Logger.info("#{st.label} stalled (> #{st.stall_ms}ms) - poll fallback, staying subscribed")
    end

    # Bewusst KEIN Stop: subscribed bleiben und auf Rueckkehr der Daten warten.
    # Timer nicht neu armen -> erst die naechste Telemetrie startet ihn wieder.
    {:noreply, %{st | streaming?: false, timer: nil}}
  end

  def handle_info(_msg, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, %{client_id: client_id}) when is_binary(client_id) do
    # Tortoise-Connection sauber abbauen (siehe @moduledoc, Teardown). disconnect/1
    # findet die Verbindung ueber die client_id und stoppt sie deregistriert. Ist
    # sie schon weg (getrappter EXIT), liefert der via-Aufruf einen :noproc-Exit,
    # den wir abfangen -> Teardown ist best-effort.
    _ = Tortoise311.Connection.disconnect(client_id)
    :ok
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _st), do: :ok

  # Warm-up-Gate: Fleet liefert die Felder einer Session nicht atomar (Payloads tragen
  # im Schnitt 48,5 von 59 Feldern). Trifft der Trigger, bevor ein Pflichtfeld je
  # gesehen wurde, entsteht eine halbleere Startzeile: beim Fahr-Feed eine Position
  # ohne Odometer (-> drives.start_km NULL -> distance NULL), beim Lade-Feed eine
  # Zeile ohne IdealBatteryRange (-> von insert_charge komplett verworfen).
  # Der Gate haelt nur bis zum ersten Emit zurueck - danach traegt FieldState die
  # Felder fort, und ein spaeter fehlendes Feld ist eine echte Aussage, kein Warm-up.
  # Nach warmup_ms wird trotzdem emittiert: lieber degraded als stumm.
  defp emit?(%{warmup?: false}, _fs, _field, _value, _now), do: true
  defp emit?(%{require_fields: [], require_hard: []}, _fs, _field, _value, _now), do: true

  defp emit?(%{} = st, fs, field, value, now) do
    st.emit_always.(field, value) or
      (hard_missing(st, fs) == [] and
         (soft_missing(st, fs) == [] or
            DateTime.diff(now, st.started_at, :millisecond) >= st.warmup_ms))
  end

  # Fuer die Logzeile: alles was fehlt, weich wie hart.
  defp missing(%{require_fields: req, require_hard: hard}, fs) do
    Enum.reject(req ++ hard, &satisfied?(&1, fs))
  end

  defp soft_missing(%{require_fields: req}, fs), do: Enum.reject(req, &satisfied?(&1, fs))
  defp hard_missing(%{require_hard: hard}, fs), do: Enum.reject(hard, &satisfied?(&1, fs))

  # Alternativgruppe: eines der Felder genuegt. Einzelfeld: es selbst muss da sein.
  defp satisfied?(alternatives, fs) when is_list(alternatives) do
    Enum.any?(alternatives, &(not is_nil(FieldState.get(fs, &1))))
  end

  defp satisfied?(field, fs) when is_binary(field) do
    not is_nil(FieldState.get(fs, field))
  end

  defp arm_timer(%{timer: t, stall_ms: ms} = st) do
    if is_reference(t), do: Process.cancel_timer(t)
    %{st | timer: Process.send_after(self(), :stall, ms)}
  end

  defp safe_emit(receiver, payload) do
    receiver.(payload)
  rescue
    e -> Logger.warning("FleetTelemetry stream receiver failed: #{inspect(e)}")
  end

  # Oeffnet die MQTT-Verbindung und gibt die verwendete (eindeutige) client_id
  # zurueck, oder nil bei Connect-Fehler (Provider laeuft dann degraded weiter,
  # ohne den FSM mitzureissen). Der eigentliche Connect ist ueber :connect_fun
  # injizierbar (Tests), Default ist die echte Tortoise-Verbindung.
  defp connect(opts, vin) do
    client_id = "TESLAMATE_FLEETSTREAM_#{vin}_#{System.unique_integer([:positive])}"
    start_fun = Keyword.get(opts, :connect_fun, &default_start(&1, opts, vin))

    case start_fun.(client_id) do
      {:ok, _conn} ->
        client_id

      {:error, {:already_started, _conn}} ->
        # Sollte mit eindeutiger client_id nicht auftreten; defensiv behandeln,
        # statt init (und damit den Vehicle-FSM) abstuerzen zu lassen.
        client_id

      {:error, reason} ->
        Logger.warning("FleetTelemetry stream connect failed: #{inspect(reason)}")
        nil
    end
  end

  defp default_start(client_id, opts, vin) do
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 1883)
    topic_base = Keyword.get(opts, :topic_base, "fleet")
    me = self()

    Tortoise311.Connection.start_link(
      client_id: client_id,
      server: {Transport.Tcp, host: host, port: port},
      handler: {Handler, [target: me, status_target: me]},
      subscriptions: [{"#{topic_base}/#{vin}/v/#", 0}]
    )
  end
end
