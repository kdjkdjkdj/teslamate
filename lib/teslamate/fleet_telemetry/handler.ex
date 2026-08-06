defmodule TeslaMate.FleetTelemetry.Handler do
  use Tortoise311.Handler
  require Logger

  @impl true
  def init(opts) do
    targets =
      case Keyword.get(opts, :targets) do
        nil -> [Keyword.fetch!(opts, :target)]
        list when is_list(list) -> list
      end

    # status_target bekommt Verbindungswechsel gemeldet - bewusst NICHT `targets`:
    # dort haengen auch die Shadow-Recorder, und deren handle_cast/2 kennt nur
    # {:ingest, ...}. Ein unbekannter Cast wuerde sie mit FunctionClauseError abraeumen.
    {:ok, %{targets: targets, status_target: Keyword.get(opts, :status_target)}}
  end

  @impl true
  def connection(:up, state) do
    Logger.info("FleetTelemetry MQTT connection established")
    notify(state, :up)
    {:ok, state}
  end

  def connection(status, state) when status in [:down, :terminating] do
    Logger.warning("FleetTelemetry MQTT connection #{status}")
    notify(state, status)
    {:ok, state}
  end

  defp notify(%{status_target: pid}, status) when is_pid(pid) do
    TeslaMate.FleetTelemetry.StreamProvider.mark_connection(pid, status)
  end

  defp notify(_state, _status), do: :ok

  @impl true
  def handle_message(topic_levels, payload, state) do
    with field when is_binary(field) <- field_from_topic(topic_levels),
         value <- decode_payload(payload) do
      Enum.each(state.targets, &GenServer.cast(&1, {:ingest, field, value}))
    else
      _ -> :ok
    end

    {:ok, state}
  end

  @doc "Feldname = Level direkt nach \"v\"; sonst nil (connectivity/errors/alerts)."
  def field_from_topic(levels) do
    case Enum.split_while(levels, &(&1 != "v")) do
      {_pre, ["v", field | _rest]} -> field
      _ -> nil
    end
  end

  def decode_payload(payload) do
    case Jason.decode(payload) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end
end
