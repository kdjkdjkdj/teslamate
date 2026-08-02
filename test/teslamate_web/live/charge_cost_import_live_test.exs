defmodule TeslaMateWeb.ChargeCostLiveTest do
  use TeslaMateWeb.ConnCase

  alias TeslaMate.Log

  defp car_fixture(attrs \\ %{}) do
    id = :erlang.unique_integer([:positive]) |> rem(100_000)
    {:ok, car} =
      attrs
      |> Enum.into(%{eid: id, vid: id, vin: "CCLV#{id}", model: "MY"})
      |> Log.create_car()
    car
  end

  test "rendert das Backfill-Formular", %{conn: conn} do
    _car = car_fixture()

    assert {:ok, _view, html} = live(conn, "/charge-cost-import")

    doc = Floki.parse_document!(html)

    # Range-Dropdown mit drei Optionen
    options =
      doc
      |> Floki.find("select[name=range] option")
      |> Floki.attribute("value")

    assert options == ["all", "last_12_months", "last_30_days"]

    # Orphan-Checkbox vorhanden
    assert [_] = Floki.find(doc, "input[name=orphans][type=checkbox]")

    # Start-Button aktiv (Auto vorhanden)
    assert [btn] = Floki.find(doc, "button.is-success")
    refute Floki.attribute(btn, "disabled") == ["disabled"]
  end

  test "zeigt Hinweis und deaktiviert Button ohne Fahrzeuge", %{conn: conn} do
    assert {:ok, _view, html} = live(conn, "/charge-cost-import")

    assert html =~ "No vehicles found"

    doc = Floki.parse_document!(html)
    assert [btn] = Floki.find(doc, "button.is-success")
    assert Floki.attribute(btn, "disabled") == ["disabled"]
  end
end