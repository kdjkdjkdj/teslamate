defmodule TeslaMate.FleetTelemetry.HandlerTest do
  use ExUnit.Case, async: true

  alias TeslaMate.FleetTelemetry.Handler

  test "field_from_topic extrahiert Feldnamen nach v" do
    assert Handler.field_from_topic(["fleet", "LRWY", "v", "Location"]) == "Location"
    assert Handler.field_from_topic(["fleet", "LRWY", "v", "PackCurrent"]) == "PackCurrent"
  end

  test "field_from_topic ignoriert nicht-v Topics (connectivity, errors)" do
    assert Handler.field_from_topic(["fleet", "LRWY", "connectivity"]) == nil
    assert Handler.field_from_topic(["fleet", "LRWY", "errors", "x"]) == nil
  end

  test "decode_payload dekodiert JSON-Skalare und null" do
    assert Handler.decode_payload("28.5") == 28.5
    assert Handler.decode_payload("\"ShiftStateD\"") == "ShiftStateD"
    assert Handler.decode_payload("null") == nil
    assert Handler.decode_payload("{\"latitude\":48.4}") == %{"latitude" => 48.4}
  end

  test "handle_message castet {:ingest, field, value} an target" do
    {:ok, state} = TeslaMate.FleetTelemetry.Handler.init(target: self())
    TeslaMate.FleetTelemetry.Handler.handle_message(["fleet", "VIN", "v", "VehicleSpeed"], "42.0", state)
    assert_receive {:"$gen_cast", {:ingest, "VehicleSpeed", 42.0}}, 200
  end

  test "handle_message fannt an mehrere targets (Position + Charge)" do
    parent = self()
    a = spawn(fn -> relay(parent, :a) end)
    b = spawn(fn -> relay(parent, :b) end)

    {:ok, state} = TeslaMate.FleetTelemetry.Handler.init(targets: [a, b])
    TeslaMate.FleetTelemetry.Handler.handle_message(["fleet", "VIN", "v", "Soc"], "63.0", state)

    assert_receive {:a, {:ingest, "Soc", 63.0}}, 200
    assert_receive {:b, {:ingest, "Soc", 63.0}}, 200
  end

  defp relay(parent, tag) do
    receive do
      {:"$gen_cast", msg} -> send(parent, {tag, msg})
    end
  end
end
