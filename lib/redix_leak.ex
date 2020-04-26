defmodule RedixLeak do
  @moduledoc """
  Documentation for `RedixLeak`.
  """

  defmodule Server do
    use GenServer

    def init(_) do
      {:ok, listen_socket} = :gen_tcp.listen(6379, [:binary, packet: 0, active: true, ip: {127, 0 ,0, 1}])
      {:ok, socket} = :gen_tcp.accept(listen_socket)

      {:ok, %{socket: socket}}
    end

    def handle_info(:publish, %{socket: socket} = state) do
      payloads =
        Enum.map(1..20_000, fn _n ->
          bin = String.duplicate("a", 100_000 + Enum.random(-1000..1000))
          "*3\r\n$7\r\nmessage\r\n$10\r\nmy_channel\r\n$#{byte_size(bin)}\r\n" <> bin <> "\r\n"
        end)
        |> Enum.join()

      :gen_tcp.send(socket, payloads)

      {:noreply, state}
    end

    def handle_info({:tcp, socket, bytes}, state) do
      case bytes do
        "*2\r\n$9\r\nSUBSCRIBE\r\n$10\r\nmy_channel\r\n" ->
          :gen_tcp.send(socket, "*3\r\n$9\r\nsubscribe\r\n$10\r\nmy_channel\r\n:0\r\n")

        other ->
          IO.inspect "Got #{inspect(other)}"
      end

      {:noreply, state}
    end

    def handle_info({:tcp_closed, _socket}, state) do
      IO.inspect "Socket closed"
      {:noreply, state}
    end

    def handle_info({:tcp_error, _socket, reason}, state) do
      IO.inspect "Connection closed due to error: #{inspect(reason)}"
      {:noreply, state}
    end
  end

  defmodule Receiver do
    use GenServer

    def init(_) do
      {:ok, %{counter: 0}}
    end

    def handle_info({:redix_pubsub, _pubsub, _ref, :message, %{channel: "my_channel", payload: _payload}}, state) do
      # IO.inspect("Received message of size #{byte_size(payload)}!")
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

    :ok
  end

  def setup_receiver do
    setup_telemetry()

    {:ok, pubsub} = Redix.PubSub.start_link("redis://localhost:6379", name: :pubsub)
    {:ok, receiver} = GenServer.start_link(Receiver, [], name: Receiver)
    {:ok, _subref} = Redix.PubSub.subscribe(pubsub, "my_channel", receiver)

    :ok
  end

  def publish do
    Enum.each(1..100, fn n ->
      Task.start(fn ->
        {:ok, conn} = Redix.start_link("redis://localhost:6379")
        Redix.command(conn, ["PUBLISH", "my_channel", :erlang.term_to_binary(List.duplicate("#{n}", 20_000))])
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

  def queue do
    :pubsub
    |> Process.whereis()
    |> queue()
  end

  def queue(pid) when is_pid(pid) do
    pid
    |> :recon.info(:memory_used)
    |> elem(1)
    |> Keyword.get(:message_queue_len)
  end

  def gc do
    :pubsub
    |> Process.whereis()
    |> :erlang.garbage_collect()
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
