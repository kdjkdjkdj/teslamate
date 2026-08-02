defmodule TeslaMate.FleetTelemetry.ShadowRecorder do
  use GenServer
  require Logger

  alias TeslaMate.FleetTelemetry.{FieldState, Mapper, Writer}

  defstruct car_id: nil, state: nil, sink: nil, map_fun: nil, gate_fun: nil
  alias __MODULE__, as: S

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  def ingest(server, field, value) when is_binary(field) do
    GenServer.cast(server, {:ingest, field, value})
  end

  @impl true
  def init(opts) do
    {:ok,
     %S{
       car_id: Keyword.fetch!(opts, :car_id),
       state: FieldState.new(trigger_field: Keyword.get(opts, :trigger_field, "Location")),
       sink: Keyword.get(opts, :sink, &default_sink/1),
       map_fun: Keyword.get(opts, :map_fun, &Mapper.to_attrs/3),
       gate_fun: Keyword.get(opts, :gate_fun, fn _fs -> true end)
     }}
  end

  @impl true
  def handle_cast({:ingest, field, value}, %S{} = s) do
    now = DateTime.utc_now()
    fs = FieldState.put(s.state, field, value, now)
    if FieldState.trigger?(fs, field) and s.gate_fun.(fs), do: materialize(s, fs, now)
    {:noreply, %S{s | state: fs}}
  end

  defp materialize(%S{} = s, fs, now) do
    attrs =
      fs
      |> FieldState.fields()
      |> s.map_fun.(s.car_id, now)
      |> Map.put(:fields_present, FieldState.present_count(fs))
      |> Map.put(:max_field_age_s, FieldState.max_age_s(fs, now))

    try do
      s.sink.(attrs)
    rescue
      e -> Logger.warning("FleetTelemetry shadow sink failed: #{inspect(e)}")
    end
  end

  defp default_sink(attrs), do: Writer.write(Writer, attrs)
end
