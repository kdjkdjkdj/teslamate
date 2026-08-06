defmodule TeslaMate.FleetTelemetry.ConnectionStatusTest do
  # Der StreamProvider ueberlebt einen Stall absichtlich - er lebt also weiter, wenn die
  # MQTT-Strecke weg ist. `Process.alive?/1` sagt dann faelschlich "alles gut". Diese Tests
  # decken den Verbindungsstatus ab, der diese Luecke schliesst.
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.{Handler, StreamProvider}

  defp start_provider do
    {:ok, pid} =
      StreamProvider.start_link(
        car_id: 1,
        vin: "CONNVIN",
        receiver: fn _ -> :ok end,
        connect?: false
      )

    on_exit(fn -> StreamProvider.stop(pid) end)
    pid
  end

  describe "StreamProvider.connected?/1" do
    test "vor der ersten Meldung gilt die Verbindung als geschlossen" do
      refute StreamProvider.connected?(start_provider())
    end

    test ":up schaltet frei" do
      pid = start_provider()
      StreamProvider.mark_connection(pid, :up)
      assert StreamProvider.connected?(pid)
    end

    test ":down schliesst wieder" do
      pid = start_provider()
      StreamProvider.mark_connection(pid, :up)
      assert StreamProvider.connected?(pid)

      StreamProvider.mark_connection(pid, :down)
      refute StreamProvider.connected?(pid)
    end

    test ":terminating zaehlt wie :down" do
      pid = start_provider()
      StreamProvider.mark_connection(pid, :up)
      StreamProvider.mark_connection(pid, :terminating)
      refute StreamProvider.connected?(pid)
    end

    test "kein Prozess -> false statt Absturz" do
      refute StreamProvider.connected?(nil)
    end

    test "toter Prozess -> false statt Absturz" do
      pid = start_provider()
      StreamProvider.stop(pid)
      refute StreamProvider.connected?(pid)
    end

    test "nicht antwortender Prozess -> false, und der Aufrufer laeuft weiter" do
      # Ein Prozess, der nie auf GenServer.call antwortet. Der kurze Timeout und das
      # gefangene Exit sind der Grund, warum der Vehicle-FSM diese Funktion gefahrlos
      # in seinem Poll-Pfad aufrufen darf.
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)

      refute StreamProvider.connected?(pid, 50)
      assert Process.alive?(self())
    end
  end

  describe "Handler meldet Verbindungswechsel" do
    test "an status_target, wenn gesetzt" do
      {:ok, state} = Handler.init(target: self(), status_target: self())

      Handler.connection(:up, state)
      assert_receive {:"$gen_cast", {:connection, :up}}, 200

      Handler.connection(:down, state)
      assert_receive {:"$gen_cast", {:connection, :down}}, 200
    end

    test "ohne status_target passiert nichts" do
      # ⚠️ Wichtig: an `targets` haengen auch die Shadow-Recorder, deren handle_cast/2 nur
      # {:ingest, ...} kennt. Ein Verbindungs-Cast dorthin wuerde sie mit
      # FunctionClauseError abraeumen - deshalb geht der Status NUR an status_target.
      {:ok, state} = Handler.init(targets: [self()])

      assert {:ok, ^state} = Handler.connection(:up, state)
      assert {:ok, ^state} = Handler.connection(:down, state)
      refute_receive {:"$gen_cast", {:connection, _}}, 100
    end
  end
end
