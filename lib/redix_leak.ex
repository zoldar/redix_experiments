defmodule RedixLeak do
  @moduledoc """
  Documentation for `RedixLeak`.
  """

  defmodule Receiver do
    use GenServer

    def init(_) do
      {:ok, []}
    end

    def handle_info({:redix_pubsub, _pubsub, _ref, :message, %{channel: "my_channel", payload: payload}}, state) do
      IO.inspect("Received message of size #{byte_size(payload)}!")
      {:noreply, state}
    end

    def handle_info({:redix_pubsub, _pubsub, _ref, :subscribed, _}, state) do
      IO.inspect("Subscribed to the channel")
      {:noreply, state}
    end

    def handle_info(other, state) do
      IO.inspect("Received: #{inspect(other)}")
      {:noreply, state}
    end
  end

  def setup_publisher do
    setup_telemetry()
  end

  def setup_receiver do
    setup_telemetry()

    {:ok, pubsub} = Redix.PubSub.start_link("redis://localhost:6379/3", name: :pubsub)
    {:ok, receiver} = GenServer.start_link(Receiver, [], name: Receiver)
    {:ok, _subref} = Redix.PubSub.subscribe(pubsub, "my_channel", receiver)

    :ok
  end

  def publish do
    Enum.each(1..100, fn n ->
      Task.start(fn ->
        {:ok, conn} = Redix.start_link("redis://localhost:6379/3")
        Redix.command(conn, ["PUBLISH", "my_channel", :erlang.term_to_binary(List.duplicate("#{n}", 50_000))])
        Redix.stop(conn)
      end)
    end)
  end

  def mem do
    :pubsub
    |> Process.whereis()
    |> mem()
  end

  def mem(pid) when is_pid(pid) do
    pid
    |> :erlang.process_info(:binary)
    |> elem(1)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
  end

  defp setup_telemetry do
    # NOOP handler to avoid issues with telemetry events piling up
    handler = fn _event, _measurements, _meta, _config ->
      :ok
    end

    :telemetry.attach("redix_pipeline_handler", [:redix, :failed_connection], handler, :no_config)
    :telemetry.attach("redix_pipeline_handler", [:redix, :disconnection], handler, :no_config)
    :telemetry.attach("redix_pipeline_handler", [:redix, :reconnection], handler, :no_config)
    :telemetry.attach("redix_pipeline_handler", [:redix, :pipeline], handler, :no_config)
    :telemetry.attach("redix_pipeline_error_handler", [:redix, :pipeline, :error], handler, :no_config)
  end
end
