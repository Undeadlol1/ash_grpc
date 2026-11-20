defmodule AshGrpc.PubSubSource do
  @moduledoc """
  Adapts PubSub broadcasts into an AshGrpc notifier stream source.
  """

  @behaviour AshGrpc.NotifierStream.Source

  @spec subscribe(keyword()) :: {:ok, map()}
  def subscribe(options) do
    pubsub = Keyword.fetch!(options, :pubsub)
    topic = Keyword.fetch!(options, :topic)
    event = Keyword.get(options, :event, "sync")

    :ok = Phoenix.PubSub.subscribe(pubsub, topic)

    if subscribed_ack = Keyword.get(options, :subscribed_ack) do
      send(subscribed_ack, {subscribed_ack_tag(options), topic})
    end

    {:ok, %{event: event, pubsub: pubsub, topic: topic}}
  end

  @spec handle_message(term(), map()) :: {:emit, map(), map()} | {:skip, map()}
  def handle_message(
        %{__struct__: Phoenix.Socket.Broadcast, topic: topic, event: event, payload: payload},
        %{topic: topic, event: event} = state
      ) do
    {:emit, payload, state}
  end

  def handle_message(_message, state) do
    {:skip, state}
  end

  @spec unsubscribe(map()) :: :ok
  def unsubscribe(%{pubsub: pubsub, topic: topic}) do
    Phoenix.PubSub.unsubscribe(pubsub, topic)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp subscribed_ack_tag(options) do
    Keyword.get(options, :subscribed_ack_tag, :ash_grpc_pub_sub_source_subscribed)
  end
end
