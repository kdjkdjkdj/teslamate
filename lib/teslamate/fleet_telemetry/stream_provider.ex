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
  """
  use GenServer
  require Logger

  alias TeslaMate.FleetTelemetry.{FieldState, Mapper, Handler}
  alias Tortoise311.Transport

  @stall_ms 90_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def ingest(server, field, value) when is_binary(field) do
    GenServer.cast(server, {:ingest, field, value})
  end

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
      streaming?: false,
      timer: nil,
      client_id: nil
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
  def handle_cast({:ingest, field, value}, st) do
    now = DateTime.utc_now()
    fs = FieldState.put(st.state, field, value, now)
    st = %{st | state: fs}

    st =
      if FieldState.trigger?(fs, field) do
        sd = st.map_fun.(FieldState.fields(fs), now)
        # Stream-Daten zuerst, dann das Freshness-Signal: so bleibt die
        # Objekt-Reihenfolge fuer den FSM eindeutig.
        safe_emit(st.receiver, sd)
        safe_emit(st.receiver, :fleet_streaming)

        if not st.streaming? do
          Logger.info("FleetTelemetry stream active - feeding live positions")
        end

        arm_timer(%{st | streaming?: true})
      else
        st
      end

    {:noreply, st}
  end

  @impl true
  def handle_info(:stall, st) do
    if st.streaming? do
      Logger.info(
        "FleetTelemetry stream stalled (> #{st.stall_ms}ms) - poll fallback, staying subscribed"
      )
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
      handler: {Handler, [target: me]},
      subscriptions: [{"#{topic_base}/#{vin}/v/#", 0}]
    )
  end
end
