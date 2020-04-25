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
  end

  def setup do
    {:ok, pubsub} = Redix.PubSub.start_link("redis://localhost:6379/3", name: :pubsub)
    {:ok, receiver} = GenServer.start_link(Receiver, [], name: Receiver)
    {:ok, _subref} = Redix.PubSub.subscribe(pubsub, "my_channel", receiver)

    :ok
  end

  def publish do
    Enum.each(1..100, fn n ->
      Task.start(fn ->
        {:ok, conn} = Redix.start_link("redis://localhost:6379/3")
        Redix.command(conn, ["PUBLISH", "my_channel", "hello#{n}"])
        Redix.stop(conn)
      end)
    end)
  end

  def mem do
    Receiver
    |> Process.whereis()
    |> :erlang.process_info()
    |> Keyword.take([:heap_size, :total_heap_size])
  end
end
