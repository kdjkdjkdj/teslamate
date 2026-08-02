defmodule TeslaMate.FleetTelemetry.FieldState do
  @moduledoc "Reiner rollender Feldzustand fuer Fleet-Telemetry (Feld -> Wert + Empfangszeit)."

  defstruct fields: %{}, received_at: %{}, trigger_field: "Location"
  alias __MODULE__, as: State

  def new(opts \\ []) do
    %State{trigger_field: Keyword.get(opts, :trigger_field, "Location")}
  end

  def put(%State{} = s, field, value, %DateTime{} = now) when is_binary(field) do
    %State{s | fields: Map.put(s.fields, field, value), received_at: Map.put(s.received_at, field, now)}
  end

  def get(%State{} = s, field), do: Map.get(s.fields, field)

  def fields(%State{} = s), do: s.fields

  def present_count(%State{} = s) do
    Enum.count(s.fields, fn {_k, v} -> not is_nil(v) end)
  end

  def max_age_s(%State{} = s, %DateTime{} = now) do
    s.received_at
    |> Map.values()
    |> Enum.map(&DateTime.diff(now, &1))
    |> Enum.max(fn -> 0 end)
  end

  def trigger?(%State{trigger_field: tf}, field) when is_list(tf), do: field in tf
  def trigger?(%State{trigger_field: tf}, field), do: field == tf
end
