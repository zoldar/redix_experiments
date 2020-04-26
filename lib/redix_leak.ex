defmodule RedixLeak do
  @moduledoc """
  Documentation for `RedixLeak`.
  """

  defmodule Receiver do
    use GenServer

    def init(_) do
      {:ok, %{counter: 0}}
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

  defmodule Publisher do
    use GenServer

    def init(_) do
      pid = Process.whereis(:pubsub)
      socket = pid |> :recon.get_state() |> elem(1) |> Map.get(:socket)

      {:ok, %{fd: nil, socket: socket}}
    end

    def handle_info(:publish, state) do
      payloads =
        Enum.map(1..2000, fn _n ->
          bin = String.duplicate("a", 100_000 + Enum.random(-1000..1000))
          "*3\r\n$7\r\nmessage\r\n$10\r\nmy_channel\r\n$#{byte_size(bin)}\r\n" <> bin <> "\r\n"
        end)
        |> Enum.join()

      File.write!("to_publish.bin", payloads)

      fd = File.open!("to_publish.bin")

      Process.send_after(self(), :send_payload, 100)

      {:noreply, %{state | fd: fd}}
    end

    def handle_info(:send_payload, %{fd: nil} = state) do
      {:noreply, state}
    end

    def handle_info(:send_payload, %{fd: fd} = state) do
      case IO.binread(fd, 300_000) do
        :eof ->
          File.close(fd)
          {:noreply, %{state | fd: nil}}
        chunk when is_binary(chunk) ->
          send(:pubsub, {:tcp, state.socket, chunk})
          {:noreply, state}
      end
    end
  end

  def setup_publisher do
    setup_telemetry()

    :ok
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
        Redix.command(conn, ["PUBLISH", "my_channel", :erlang.term_to_binary(List.duplicate("#{n}", 20_000))])
        Redix.stop(conn)
      end)
    end)
  end

  def start_publisher_emulator do
    GenServer.start_link(Publisher, [], name: Publisher)
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
