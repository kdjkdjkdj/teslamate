defmodule TeslaMate.FleetTelemetry.DebounceTest do
  # Der Lade-Provider triggert auf DREI Feldern (DetailedChargeState, DC-/ACChargingEnergyIn),
  # alle mit 30 s konfiguriert. Landen zwei davon im selben Payload, feuerte er ZWEI Emits mit
  # derselben Ereigniszeit. Gemessen an Ladung #390 (05.08.2026, 92 min): 77 Zeilenpaare auf die
  # Millisekunde gleich - bei unterschiedlichem charge_energy_added, weil der zweite Emit einen
  # neueren Feldzustand sah. 183 von 368 Abstaenden lagen unter 2 s.
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.StreamProvider

  defp start(opts) do
    me = self()

    {:ok, pid} =
      StreamProvider.start_link(
        Keyword.merge(
          [
            car_id: 1,
            vin: "DEBVIN",
            connect?: false,
            receiver: fn x -> send(me, {:aus, x}) end,
            trigger_field: ["A", "B"],
            map_fun: fn fields, _now -> {Map.get(fields, "A"), Map.get(fields, "B")} end
          ],
          opts
        )
      )

    on_exit(fn -> StreamProvider.stop(pid) end)
    pid
  end

  test "ohne Entprellen bleibt es bei einem Emit je Trigger (Default unveraendert)" do
    pid = start([])
    StreamProvider.ingest(pid, "A", 1)
    StreamProvider.ingest(pid, "B", 2)

    assert_receive {:aus, {1, nil}}, 300
    assert_receive {:aus, :fleet_streaming}, 300
    assert_receive {:aus, {1, 2}}, 300
  end

  test "mit Entprellen wird aus zwei Triggern im Fenster EIN Emit" do
    pid = start(debounce_ms: 120)
    StreamProvider.ingest(pid, "A", 1)
    StreamProvider.ingest(pid, "B", 2)

    # Der eine Emit traegt beide Felder - das ist der Sinn des Sammelns.
    assert_receive {:aus, {1, 2}}, 500
    assert_receive {:aus, :fleet_streaming}, 300
    refute_receive {:aus, {_, _}}, 300
  end

  test "das Fenster wird nicht verlaengert, nur der juengste Ausloeser zaehlt" do
    pid = start(debounce_ms: 120)
    StreamProvider.ingest(pid, "A", 1)
    Process.sleep(60)
    StreamProvider.ingest(pid, "B", 2)

    assert_receive {:aus, {1, 2}}, 500
    refute_receive {:aus, {_, _}}, 300
  end

  test "nach dem Fenster loest der naechste Trigger wieder aus" do
    pid = start(debounce_ms: 100)
    StreamProvider.ingest(pid, "A", 1)
    assert_receive {:aus, {1, nil}}, 500

    StreamProvider.ingest(pid, "B", 2)
    assert_receive {:aus, {1, 2}}, 500
  end

  test "die emit_always-Kante wird NIE aufgeschoben" do
    # Beim Lade-Feed ist das die Stopped/Complete-Kante: sie muss sofort durch, sonst bliebe
    # der charging_process offen. Ein Aufschub waere hier gefaehrlicher als ein Duplikat.
    pid = start(debounce_ms: 5_000, emit_always: fn field, _value -> field == "B" end)
    StreamProvider.ingest(pid, "B", 2)

    assert_receive {:aus, {nil, 2}}, 300
  end

  test "eine wartende Entprellung wird von der emit_always-Kante abgeraeumt, nicht verdoppelt" do
    pid = start(debounce_ms: 400, emit_always: fn field, _value -> field == "B" end)
    StreamProvider.ingest(pid, "A", 1)
    StreamProvider.ingest(pid, "B", 2)

    assert_receive {:aus, {1, 2}}, 300
    assert_receive {:aus, :fleet_streaming}, 300
    # Der zurueckgestellte Emit darf nicht nachtroepfeln, wenn sein Timer spaeter feuert.
    refute_receive {:aus, {_, _}}, 700
  end
end
