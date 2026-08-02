defmodule TeslaMate.ChargeCost.Orphan do
  @moduledoc """
  Legt einen minimalen `charging_process` fuer eine von Tesla abgerechnete Session an,
  zu der es keinen TeslaMate-Ladevorgang gibt (z.B. Ladung waehrend TeslaMate aus war).

  Hinweis: `charging_processes.position_id` ist NOT NULL -> wir muessen eine Position
  mitliefern. Orphans haben keine echte GPS-Spur, daher 0/0 als Platzhalter. Damit der
  Repair-Worker die 0/0-Position nicht zu "Unknown" geocodiert, bekommt der Orphan eine
  synthetische Adresse mit dem Standortnamen (`siteLocationName` aus der History-API)
  gesetzt -- Repair ueberspringt charging_processes mit gesetzter `address_id`.
  """

  alias TeslaMate.{Repo, Log.Car, Log.ChargingProcess}
  alias TeslaMate.Locations.Address
  alias TeslaMate.ChargeCost.Fee

  @spec create(Car.t(), map(), :gross | :net) :: :ok | {:error, Ecto.Changeset.t()}
  def create(%Car{id: car_id}, session, basis) do
    attrs = %{
      start_date: session.start_date,
      end_date: session.end_date,
      charge_energy_added: session.energy_kwh,
      duration_min: duration_min(session),
      cost: Fee.total(session, basis),
      address_id: site_address_id(session.site),
      position: %{
        car_id: car_id,
        date: session.start_date,
        latitude: 0.0,
        longitude: 0.0
      }
    }

    %ChargingProcess{car_id: car_id}
    |> ChargingProcess.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, _cp} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end

  # Synthetische Adresse pro SuC-Standortname, dedupliziert ueber (osm_id, osm_type).
  # osm_type "suc" kollidiert nie mit echten OSM-Adressen (node/way/relation), daher
  # verfaelscht die synthetische osm_id (phash2 des Namens) keine echten Eintraege.
  defp site_address_id(nil), do: nil
  defp site_address_id(""), do: nil

  defp site_address_id(site) when is_binary(site) do
    osm_id = :erlang.phash2(site)

    case Repo.get_by(Address, osm_id: osm_id, osm_type: "suc") do
      %Address{id: id} ->
        id

      nil ->
        %Address{}
        |> Address.changeset(%{
          name: site,
          display_name: site,
          latitude: 0.0,
          longitude: 0.0,
          osm_id: osm_id,
          osm_type: "suc",
          raw: %{"synthetic" => true, "source" => "dx/charging/history", "site" => site}
        })
        |> Repo.insert()
        |> case do
          {:ok, %Address{id: id}} -> id
          {:error, _} -> fallback_address_id(osm_id)
        end
    end
  end

  defp fallback_address_id(osm_id) do
    case Repo.get_by(Address, osm_id: osm_id, osm_type: "suc") do
      %Address{id: id} -> id
      nil -> nil
    end
  end

  defp duration_min(%{start_date: s, end_date: e}) when not is_nil(s) and not is_nil(e) do
    DateTime.diff(e, s, :second) |> div(60)
  end

  defp duration_min(_), do: nil
end
