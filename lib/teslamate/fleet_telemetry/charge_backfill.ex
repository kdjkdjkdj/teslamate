defmodule TeslaMate.FleetTelemetry.ChargeBackfill do
  @moduledoc """
  Traegt im Offline-Sleep von TeslaMate verpasste Ladungen nach: scannt die
  Charge-Shadow-Daten (`fleet_telemetry_charges`) nach abgeschlossenen Sessions
  ohne ueberlappenden `charging_process` und rekonstruiert sie ueber die
  bestehenden `Log`-Funktionen. Ausgeloest durch `trigger/1` beim FSM-Uebergang
  zurueck nach :online. Idempotent (Ueberlappungs-Check + Marker-Tabelle).
  """
  use GenServer
  require Logger
  import Ecto.Query

  alias TeslaMate.FleetTelemetry.ChargeBackfill.{Detector, Reconstructor}
  alias TeslaMate.FleetTelemetry.{ShadowCharge, BackfillMarker}
  alias TeslaMate.{Repo, Log}
  alias TeslaMate.Log.{Car, ChargingProcess, Position}

  @window_days 7

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Stoesst einen Scan fuer `car_id` an. No-op, wenn der GenServer nicht laeuft (Flag aus)."
  def trigger(car_id) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:scan, car_id})
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:scan, car_id}, state) do
    scan(car_id)
    {:noreply, state}
  end

  @doc """
  Ein Scan-Durchlauf fuer `car_id`: laedt Shadow-Zeilen + cprocs + Marker der
  letzten #{@window_days} Tage, bildet Sessions, filtert (Ueberlappung, Rausch,
  bereits nachgetragen) und rekonstruiert die verbliebenen. `deps` erlaubt das
  Injizieren der `Log`-Aufrufe fuer Tests.
  """
  def scan(car_id, deps \\ deps()) do
    since = DateTime.add(DateTime.utc_now(), -@window_days * 86_400, :second)

    rows =
      Repo.all(
        from s in ShadowCharge,
          where: s.car_id == ^car_id and s.date >= ^since,
          order_by: s.date
      )

    # Fenstergrenze am ENDE pruefen, nicht am Start: ein per Poll erfasster
    # Vorgang, der vor `since` begann und in das Fenster hineinreicht, muss in
    # der Vergleichsliste stehen. Sonst faellt er heraus, waehrend die (spaeter
    # beginnende) Shadow-Session noch drin ist -- und der Ueberlappungs-Filter
    # laeuft ins Leere. Genau so entstanden am 04./05./13./20.08.2026 fuenf
    # doppelt angelegte Ladevorgaenge, jeweils exakt 7 Tage nach der Ladung.
    cprocs =
      Repo.all(
        from c in ChargingProcess,
          where: c.car_id == ^car_id and (is_nil(c.end_date) or c.end_date >= ^since),
          select: %{start_date: c.start_date, end_date: c.end_date}
      )

    markers =
      Repo.all(
        from m in BackfillMarker,
          where: m.car_id == ^car_id,
          select: {m.session_start, m.session_end}
      )
      |> MapSet.new()

    car = Repo.get!(Car, car_id)

    rows
    |> Detector.cluster_sessions(now: DateTime.utc_now())
    |> Enum.reject(&Detector.overlaps?(&1, cprocs))
    |> Enum.filter(&Detector.charging_session?/1)
    |> Enum.filter(&Detector.significant?/1)
    |> Enum.reject(fn s -> MapSet.member?(markers, {s.start, s.end}) end)
    |> Enum.each(&backfill_one(car, &1, deps))

    :ok
  end

  defp backfill_one(%Car{id: car_id} = car, session, deps) do
    case charge_position(car_id, session) do
      nil ->
        Logger.warning(
          "ChargeBackfill: keine Position fuer Session #{session.start}, uebersprungen",
          car_id: car_id
        )

      pos ->
        Repo.transaction(fn ->
          {:ok, cproc} = Reconstructor.reconstruct(car, session, pos, deps)

          %BackfillMarker{}
          |> BackfillMarker.changeset(%{
            car_id: car_id,
            session_start: session.start,
            session_end: session.end,
            charging_process_id: cproc.id
          })
          |> Repo.insert!()

          cproc
        end)
        |> case do
          {:ok, cproc} ->
            Logger.info(
              "ChargeBackfill: Ladung nachgetragen (cp #{cproc.id}, #{session.start}..#{session.end})",
              car_id: car_id
            )

          {:error, reason} ->
            Logger.warning("ChargeBackfill fehlgeschlagen (#{session.start}): #{inspect(reason)}",
              car_id: car_id
            )
        end
    end
  end

  # Ladeort: naechste Position nach Session-Ende, sonst letzte davor. lat/lng + Start-Werte.
  defp charge_position(car_id, session) do
    first = hd(session.rows)

    geo =
      Repo.one(
        from p in Position,
          where: p.car_id == ^car_id and p.date >= ^session.end,
          order_by: [asc: p.date],
          limit: 1,
          select: %{latitude: p.latitude, longitude: p.longitude}
      ) ||
        Repo.one(
          from p in Position,
            where: p.car_id == ^car_id and p.date <= ^session.start,
            order_by: [desc: p.date],
            limit: 1,
            select: %{latitude: p.latitude, longitude: p.longitude}
        )

    case geo do
      nil ->
        nil

      %{latitude: lat, longitude: lng} ->
        %{
          latitude: lat,
          longitude: lng,
          date: session.start,
          battery_level: first.battery_level,
          usable_battery_level: first.usable_battery_level,
          ideal_battery_range_km: first.ideal_battery_range_km,
          rated_battery_range_km: first.rated_battery_range_km
        }
    end
  end

  defp deps do
    %{
      log: %{
        start_charging_process: &Log.start_charging_process/3,
        insert_charge: &Log.insert_charge/2,
        complete_charging_process: &Log.complete_charging_process/1
      }
    }
  end
end
