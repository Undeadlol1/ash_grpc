defmodule AshGrpc.TestSupport.NotifierStreamRequest do
  @moduledoc false
  defstruct [:user_id, :limit, :subscribed_ack]
end

defmodule AshGrpc.TestSupport.NotifierStreamReply do
  @moduledoc false
  defstruct [:action, :resource, :record_count]
end

defmodule AshGrpc.TestSupport.NotifierStreamRequestMapper do
  @moduledoc false

  alias AshGrpc.TestSupport.NotifierStreamRequest

  def to_ash_input(%NotifierStreamRequest{
        user_id: user_id,
        limit: limit,
        subscribed_ack: subscribed_ack
      }) do
    {:ok, %{user: %{id: user_id}, limit: limit, subscribed_ack: subscribed_ack}}
  end
end

defmodule AshGrpc.TestSupport.NotifierStreamResponseMapper do
  @moduledoc false

  alias AshGrpc.TestSupport.NotifierStreamReply

  def to_response(%{action: action, resource: resource, data: records}) when is_list(records) do
    {:ok, %NotifierStreamReply{action: action, resource: resource, record_count: length(records)}}
  end
end

defmodule AshGrpc.TestSupport.FakeNotifierSource do
  @moduledoc false

  @behaviour AshGrpc.NotifierStream.Source

  def subscribe(options) do
    emitter = spawn_link(fn -> emitter_loop() end)

    if subscribed_ack = Keyword.get(options, :subscribed_ack) do
      send(subscribed_ack, {:fake_notifier_subscribed, emitter})
    end

    {:ok, %{emitter: emitter}}
  end

  def handle_message({:fake_notifier_event, payload}, state) do
    {:emit, payload, state}
  end

  def handle_message(:fake_notifier_stop, state) do
    {:stop, state}
  end

  def handle_message(_message, state) do
    {:skip, state}
  end

  def unsubscribe(%{emitter: emitter}) do
    monitor_ref = Process.monitor(emitter)
    send(emitter, {:stop, self()})

    receive do
      {:fake_notifier_stopped, ^emitter} ->
        receive do
          {:DOWN, ^monitor_ref, :process, ^emitter, _reason} -> :ok
        end
    end
  end

  defp emitter_loop do
    receive do
      {:stop, caller} ->
        send(caller, {:fake_notifier_stopped, self()})

        :ok

      _other ->
        emitter_loop()
    end
  end
end

defmodule AshGrpc.TestSupport.FailingNotifierSource do
  @moduledoc false

  @behaviour AshGrpc.NotifierStream.Source

  def subscribe(_options) do
    {:error, :boom}
  end

  def handle_message(_message, state) do
    {:skip, state}
  end

  def unsubscribe(_state) do
    :ok
  end
end

defmodule AshGrpc.TestSupport.NotifierStreamHandler do
  @moduledoc false

  alias AshGrpc.PubSubSource

  def stream_sync(%{user: user, limit: limit, subscribed_ack: subscribed_ack}) do
    topic = "ash-grpc-notifier-stream:#{user.id}"

    {:ok,
     AshGrpc.NotifierStream.stream(PubSubSource,
       pubsub: AshGrpc.TestPubSub,
       topic: topic,
       event: "sync",
       subscribed_ack_tag: :stream_subscribed,
       limit: limit,
       subscribed_ack: subscribed_ack
     )}
  end
end

defmodule AshGrpc.TestSupport.NotifierStreamDesk do
  @moduledoc false

  use Ash.Domain,
    validate_config_inclusion?: false,
    extensions: [AshGrpc.Domain]

  alias AshGrpc.Examples.SupportTicket
  alias AshGrpc.TestSupport.NotifierStreamHandler
  alias AshGrpc.TestSupport.NotifierStreamRequestMapper
  alias AshGrpc.TestSupport.NotifierStreamResponseMapper

  grpc do
    routes do
      service "/notifier" do
        server_stream(:stream_sync, SupportTicket, :read,
          handler: NotifierStreamHandler,
          request_mapper: NotifierStreamRequestMapper,
          response_mapper: NotifierStreamResponseMapper
        )
      end
    end
  end

  resources do
    resource SupportTicket do
      define(:stream_sync, action: :read)
    end
  end
end
