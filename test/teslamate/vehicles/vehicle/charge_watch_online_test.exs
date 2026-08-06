defmodule TeslaMate.Vehicles.Vehicle.ChargeWatchOnlineTest do
  # Schwester von charge_watch_test.exs: dort der Weckpfad aus dem Suspend, hier der
  # Vorzieh-Pfad im Wachzustand.
  #
  # ⚠️ In Mix.env() == :test ist fetch_timeout/2 die Identitaet - jedes "Intervall" zaehlt
  # Millisekunden, nicht Sekunden. Ein wacher, am Suspend gehinderter Wagen pollt hier also
  # alle 15 ms und ein vorgezogener Poll waere nicht unterscheidbar. Deshalb setzt der Test
  # POLLING_DEFAULT_INTERVAL auf 3000 (= 3 s im Test) und nutzt den user_present-Zweig, der
  # genau dieses Intervall verwendet. Alles, was innerhalb einer Sekunde pollt, ist damit
  # nachweislich vorgezogen und nicht regulaer.
  use TeslaMate.VehicleCase, async: false

  alias TeslaMate.Vehicles.Vehicle.Summary

  setup do
    System.put_env("POLLING_DEFAULT_INTERVAL", "3000")
    on_exit(fn -> System.delete_env("POLLING_DEFAULT_INTERVAL") end)
    :ok
  end

  # is_user_present haelt das Auto in :online: can_fall_asleep/2 gibt {:error, :user_present},
  # es wird nicht suspendiert und pollt im default_interval-Takt. Das ist zugleich der Zweig,
  # der im Feld am teuersten war (gemessen 2026-08-05: 15-s-Poll ueber Minuten).
  defp blocked(ts) do
    online_event(ts,
      drive_state: %{timestamp: ts, latitude: 0.0, longitude: 0.0},
      vehicle_state: %{timestamp: ts, car_version: "", is_user_present: true}
    )
  end

  defp start_online(name) do
    now_ts = DateTime.utc_now() |> DateTime.to_unix(:millisecond)
    me = self()

    # EIN Ereignis, das sich wiederholt (ApiMock behaelt das letzte): so meldet sich jeder
    # Poll. Mit einer Liste aus Tupeln + abschliessender Funktion waere der Mock je nach
    # Anzahl der Startpolls noch gar nicht bei der Funktion - dann bleibt es still, und der
    # Test misst nichts.
    events = [fn -> send(me, :fetched); {:ok, blocked(now_ts)} end]

    :ok = start_vehicle(name, events)

    assert_receive {:start_state, _car, :online, date: _}
    assert_receive {:pubsub, {:broadcast, _, _, %Summary{state: :online}}}

    # Startphase durchlaufen lassen, danach ist der naechste regulaere Poll 3 s entfernt.
    :ok = quiet()
  end

  defp quiet do
    receive do
      :fetched -> quiet()
    after
      800 -> :ok
    end
  end

  @tag :capture_log
  test "ein Ladebeginn zieht den Poll sofort vor", %{test: name} do
    start_online(name)

    send(name, {:charge_watch, "DetailedChargeStateCharging"})

    assert_receive :fetched, 1_000
  end

  @tag :capture_log
  test "auch die Starting-Kante zieht vor", %{test: name} do
    start_online(name)

    send(name, {:charge_watch, "DetailedChargeStateStarting"})

    assert_receive :fetched, 1_000
  end

  @tag :capture_log
  test "eine andere Phase zieht NICHT vor", %{test: name} do
    start_online(name)

    send(name, {:charge_watch, "DetailedChargeStateDisconnected"})

    refute_receive :fetched, 800
  end

  @tag :capture_log
  test "das Freshness-Signal des Providers zieht NICHT vor", %{test: name} do
    start_online(name)

    send(name, {:charge_watch, :fleet_streaming})

    refute_receive :fetched, 800
  end

  @tag :capture_log
  test "ein zweites Signal im Debounce-Fenster loest keinen zweiten Poll aus", %{test: name} do
    # Der Waechter kennt keine Freshness-Semantik und darf dieselbe Phase mehrfach melden.
    # Ohne Mindestabstand wuerde daraus ein Poll je Feed-Ereignis - genau das, was die
    # Parkdrosselung einsparen soll.
    start_online(name)

    send(name, {:charge_watch, "DetailedChargeStateCharging"})
    assert_receive :fetched, 1_000

    send(name, {:charge_watch, "DetailedChargeStateCharging"})
    refute_receive :fetched, 800
  end
end
