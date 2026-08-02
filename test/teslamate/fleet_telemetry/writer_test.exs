defmodule TeslaMate.FleetTelemetry.WriterTest do
  use ExUnit.Case, async: true
  alias TeslaMate.FleetTelemetry.Writer

  test "write leitet attrs an die insert-Funktion weiter" do
    test_pid = self()
    fun = fn attrs -> send(test_pid, {:inserted, attrs}) end
    {:ok, w} = Writer.start_link(name: nil, insert_fun: fun)

    assert Writer.write(w, %{car_id: 1, latitude: 1.0}) == :ok
    assert_receive {:inserted, %{car_id: 1}}, 200
  end

  test "insert-Fehler crasht den Writer nicht" do
    test_pid = self()

    fun = fn attrs ->
      if attrs.car_id == 0, do: raise("boom"), else: send(test_pid, {:inserted, attrs})
    end

    {:ok, w} = Writer.start_link(name: nil, insert_fun: fun)

    Writer.write(w, %{car_id: 0})
    refute_receive {:inserted, _}, 50
    assert Process.alive?(w)

    Writer.write(w, %{car_id: 9})
    assert_receive {:inserted, %{car_id: 9}}, 200
  end
end
