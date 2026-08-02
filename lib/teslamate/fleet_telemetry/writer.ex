defmodule TeslaMate.FleetTelemetry.Writer do
  @moduledoc "Asynchroner Writer fuer Schatten-Positionen; entkoppelt DB-Inserts vom Recorder-Mailbox."
  use GenServer
  require Logger

  alias TeslaMate.FleetTelemetry.ShadowPosition
  alias TeslaMate.Repo

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  def write(server \\ __MODULE__, attrs) when is_map(attrs) do
    GenServer.cast(server, {:insert, attrs})
  end

  @impl true
  def init(opts) do
    {:ok, %{insert_fun: Keyword.get(opts, :insert_fun, &default_insert/1)}}
  end

  @impl true
  def handle_cast({:insert, attrs}, state) do
    try do
      state.insert_fun.(attrs)
    rescue
      e -> Logger.warning("FleetTelemetry writer insert failed: #{inspect(e)}")
    end

    {:noreply, state}
  end

  defp default_insert(attrs) do
    %ShadowPosition{}
    |> ShadowPosition.changeset(attrs)
    |> Repo.insert()
  end
end
