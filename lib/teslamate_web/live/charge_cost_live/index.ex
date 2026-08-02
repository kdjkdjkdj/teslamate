defmodule TeslaMateWeb.ChargeCostLive.Index do
  use TeslaMateWeb, :live_view

  alias TeslaMate.Log
  alias TeslaMate.ChargeCost.Backfill

  on_mount {TeslaMateWeb.InitAssigns, :locale}

  @impl true
  def mount(_params, %{"settings" => settings}, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(TeslaMate.PubSub, Backfill.topic())

    socket =
      socket
      |> assign(
        cars: Log.list_cars(),
        basis: settings.suc_cost_basis,
        results: %{},
        running?: false,
        page_title: gettext("Supercharger Cost Import")
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("run", %{"range" => range, "orphans" => orphans}, socket) do
    %{cars: cars, basis: basis} = socket.assigns
    create? = orphans == "true"
    rng = String.to_existing_atom(range)
    topic = Backfill.topic()

    for car <- cars do
      Task.start(fn ->
        res = Backfill.run(car, range: rng, create_orphans?: create?, basis: basis)
        Phoenix.PubSub.broadcast(TeslaMate.PubSub, topic, {:backfill_result, car, res})
      end)
    end

    {:noreply, assign(socket, running?: true, results: %{})}
  end

  @impl true
  def handle_info({:backfill_result, car, result}, socket) do
    results = Map.put(socket.assigns.results, car.id, {car, result})
    running? = map_size(results) < length(socket.assigns.cars)
    {:noreply, assign(socket, results: results, running?: running?)}
  end
end