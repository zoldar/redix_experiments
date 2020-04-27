defmodule RedixLeak do
  @moduledoc """
  Documentation for `RedixLeak`.

  Sequence of operations to reproduce the issue:

  - Run 1st instance of iex shell with `iex -S mix`
  - [1st instance] `{:ok, e} = GenServer.start_link(RedixLeak.Server, [])`
  - Run 2nd instance of iex shell with `iex -S mix`
  - [2nd instance] `RedixLeak.setup_receiver`
  - [1st instance] `send(e, :publish)`

  After that, the output on the 2nd instance should show something like this:

  ```
  "Continuation left"
  "Binary refs size: 670080"
  "Continuation left"
  "Binary refs size: 1740951"
  "Continuation left"
  "Binary refs size: 2550146"
  "Continuation left"
  "Binary refs size: 3366746"
  "Continuation left"
  ...
  "Binary refs size: 17144298"
  "Continuation left"
  "Binary refs size: 17879602"
  "Continuation left"
  "Binary refs size: 18696202"
  "Continuation left"
  "Binary refs size: 19512802"
  "Continuation left"
  "Binary refs size: 29513142"
  "Continuation left"

  ... the binary refs size keeps growing
  ```
  """

  defmodule Server do
    use GenServer

    def init(_) do
      {:ok, listen_socket} = :gen_tcp.listen(6379, [:binary, packet: 0, active: true, ip: {127, 0 ,0, 1}])
      {:ok, socket} = :gen_tcp.accept(listen_socket)

      {:ok, %{socket: socket, listen_socket: listen_socket}}
    end

    def handle_info(:publish, %{socket: socket} = state) do
      bin = String.duplicate("a", 2_000_000)

      payload = "*3\r\n$7\r\nmessage\r\n$10\r\nmy_channel\r\n$20000000\r\n" <> bin

      :gen_tcp.send(socket, payload)

      Process.send_after(self(), :disconnect_peer, 100)

      {:noreply, state}
    end

    def handle_info(:disconnect_peer, %{socket: socket, listen_socket: listen_socket} = state) do
      :gen_tcp.close(socket)

      {:ok, socket} = :gen_tcp.accept(listen_socket)

      Process.send_after(self(), :publish, 100)

      {:noreply, %{state | socket: socket}}
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

    def handle_info({:redix_pubsub, _pubsub, _ref, :message, %{channel: "my_channel", payload: payload}}, state) do
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
