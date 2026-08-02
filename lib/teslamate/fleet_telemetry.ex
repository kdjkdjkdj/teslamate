defmodule TeslaMate.FleetTelemetry do
  use Supervisor

  alias TeslaMate.FleetTelemetry.{Handler, ShadowRecorder, ShadowCharge, Writer, Mapper, FieldState}
  alias TeslaMate.Repo
  alias Tortoise311.Transport

  # Namen der zweiten (Charge-)Instanzen von Writer/Recorder.
  @charge_writer __MODULE__.ChargeWriter
  @charge_recorder __MODULE__.ChargeRecorder

  # Trigger fuer den Charge-Schatten: die (dicht ankommenden) Energy-In-Felder
  # plus DetailedChargeState, damit Start/Ende-Kanten als eigene Zeile erfasst werden.
  @charge_triggers ~w(DCChargingEnergyIn ACChargingEnergyIn DetailedChargeState)

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    car_id = Keyword.fetch!(opts, :car_id)
    vin = Keyword.fetch!(opts, :vin)
    topic_base = Keyword.get(opts, :topic_base, "fleet")
    host = Keyword.get(opts, :host, "localhost")
    port = Keyword.get(opts, :port, 1883)

    client_id = "TESLAMATE_FLEET_" <> vin
    recorder_name = ShadowRecorder

    children = [
      Supervisor.child_spec({Writer, []}, id: :position_writer),
      Supervisor.child_spec({Writer, [name: @charge_writer, insert_fun: &insert_charge_shadow/1]},
        id: :charge_writer
      ),
      Supervisor.child_spec({ShadowRecorder, car_id: car_id, name: recorder_name},
        id: :position_recorder
      ),
      Supervisor.child_spec(
        {ShadowRecorder,
         car_id: car_id,
         name: @charge_recorder,
         trigger_field: @charge_triggers,
         map_fun: &Mapper.to_charge_attrs/3,
         gate_fun: &charge_gate/1,
         sink: &charge_sink/1},
        id: :charge_recorder
      ),
      {Tortoise311.Connection,
       client_id: client_id,
       server: {Transport.Tcp, host: host, port: port},
       handler: {Handler, [targets: [recorder_name, @charge_recorder]]},
       subscriptions: [{"#{topic_base}/#{vin}/v/#", 0}]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Gate: nur materialisieren, wenn der rollende DetailedChargeState eine
  # Lade-Lifecycle-Phase ist -> keine Zeilen beim Fahren/Parken.
  defp charge_gate(fs), do: Mapper.charging_lifecycle?(FieldState.get(fs, "DetailedChargeState"))

  defp charge_sink(attrs), do: Writer.write(@charge_writer, attrs)

  defp insert_charge_shadow(attrs) do
    %ShadowCharge{}
    |> ShadowCharge.changeset(attrs)
    |> Repo.insert()
  end
end
