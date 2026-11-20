defmodule AshGrpc.PubSubSourceTest do
  use ExUnit.Case, async: true

  alias Phoenix.Socket.Broadcast

  describe "GIVEN the pubsub source" do
    test "WHEN a subscription handles a matching and an ignored broadcast THEN only the matching one is emitted" do
      assert {:ok, state} =
               AshGrpc.PubSubSource.subscribe(
                 pubsub: AshGrpc.TestPubSub,
                 topic: "ash-grpc-pubsub-source-test",
                 event: "sync",
                 subscribed_ack: self()
               )

      assert_receive {:ash_grpc_pub_sub_source_subscribed, "ash-grpc-pubsub-source-test"}

      assert {:emit, %{action: :update}, ^state} =
               AshGrpc.PubSubSource.handle_message(
                 %Broadcast{
                   topic: "ash-grpc-pubsub-source-test",
                   event: "sync",
                   payload: %{action: :update}
                 },
                 state
               )

      assert {:skip, ^state} =
               AshGrpc.PubSubSource.handle_message(
                 %Broadcast{
                   topic: "ash-grpc-pubsub-source-test",
                   event: "ignore",
                   payload: %{}
                 },
                 state
               )

      assert :ok = AshGrpc.PubSubSource.unsubscribe(state)
    end

    test "WHEN a broadcast arrives on another topic with the same event THEN it is skipped" do
      assert {:ok, state} =
               AshGrpc.PubSubSource.subscribe(
                 pubsub: AshGrpc.TestPubSub,
                 topic: "ash-grpc-topic-filter-test",
                 event: "sync"
               )

      assert {:skip, ^state} =
               AshGrpc.PubSubSource.handle_message(
                 %Broadcast{
                   topic: "different-topic",
                   event: "sync",
                   payload: %{action: :wrong_topic}
                 },
                 state
               )

      assert :ok = AshGrpc.PubSubSource.unsubscribe(state)
    end

    test "WHEN a custom subscription ack tag is requested THEN the ack arrives under that tag" do
      assert {:ok, state} =
               AshGrpc.PubSubSource.subscribe(
                 pubsub: AshGrpc.TestPubSub,
                 topic: "ash-grpc-custom-ack-test",
                 subscribed_ack: self(),
                 subscribed_ack_tag: :custom_ack
               )

      assert_receive {:custom_ack, "ash-grpc-custom-ack-test"}
      assert :ok = AshGrpc.PubSubSource.unsubscribe(state)
    end

    test "WHEN a broadcast is sent to a generic pubsub topic THEN it is streamed as an item" do
      test_pid = self()

      task =
        Task.async(fn ->
          AshGrpc.PubSubSource
          |> AshGrpc.NotifierStream.stream(
            pubsub: AshGrpc.TestPubSub,
            topic: "ash-grpc-pubsub-stream-test",
            event: "sync",
            limit: 1,
            subscribed_ack: test_pid
          )
          |> Enum.take(1)
        end)

      assert_receive {:ash_grpc_pub_sub_source_subscribed, "ash-grpc-pubsub-stream-test"}

      Phoenix.PubSub.broadcast(
        AshGrpc.TestPubSub,
        "ash-grpc-pubsub-stream-test",
        %Broadcast{
          topic: "ash-grpc-pubsub-stream-test",
          event: "sync",
          payload: %{action: :create, resource: "SupportTicket"}
        }
      )

      assert [%{action: :create, resource: "SupportTicket"}] = Task.await(task)
    end

    test "WHEN unsubscribing while the pubsub is not running THEN the answer is ok" do
      assert :ok = AshGrpc.PubSubSource.unsubscribe(%{pubsub: :no_such_pubsub, topic: "gone"})
    end
  end
end
