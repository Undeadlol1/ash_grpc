defmodule AshGrpc.NotifierStreamTest do
  use ExUnit.Case, async: true

  alias AshGrpc.TestSupport.FailingNotifierSource
  alias AshGrpc.TestSupport.FakeNotifierSource
  alias AshGrpc.TestSupport.NotifierStreamDesk
  alias AshGrpc.TestSupport.NotifierStreamReply
  alias AshGrpc.TestSupport.NotifierStreamRequest

  describe "GIVEN the notifier stream" do
    test "WHEN a notifier source is streamed THEN an enumerable is built from it" do
      test_pid = self()

      task =
        Task.async(fn ->
          FakeNotifierSource
          |> AshGrpc.NotifierStream.stream(subscribed_ack: test_pid, limit: 1)
          |> Enum.take(1)
        end)

      assert_receive {:fake_notifier_subscribed, emitter}
      send(task.pid, {:fake_notifier_event, %{value: 42}})

      assert [%{value: 42}] = Task.await(task)
      refute Process.alive?(emitter)
    end

    test "WHEN the timeout is infinity THEN a long-lived subscription keeps waiting for events" do
      test_pid = self()

      task =
        Task.async(fn ->
          FakeNotifierSource
          |> AshGrpc.NotifierStream.stream(
            subscribed_ack: test_pid,
            limit: 1,
            timeout: :infinity
          )
          |> Enum.take(1)
        end)

      assert_receive {:fake_notifier_subscribed, _emitter}
      refute_receive {:fake_notifier_event, _}, 50
      send(task.pid, {:fake_notifier_event, %{value: :late}})

      assert [%{value: :late}] = Task.await(task)
    end

    test "WHEN an invalid idle timeout is given THEN an argument error is raised" do
      assert_raise ArgumentError, ~r/positive integer or :infinity/, fn ->
        FakeNotifierSource
        |> AshGrpc.NotifierStream.stream(subscribed_ack: self(), timeout: -1)
        |> Enum.take(1)
      end
    end

    test "WHEN the notifier source requests stop THEN the stream halts cleanly" do
      test_pid = self()

      task =
        Task.async(fn ->
          FakeNotifierSource
          |> AshGrpc.NotifierStream.stream(subscribed_ack: test_pid, limit: 5)
          |> Enum.to_list()
        end)

      assert_receive {:fake_notifier_subscribed, emitter}
      send(task.pid, :fake_notifier_stop)

      assert [] = Task.await(task)
      refute Process.alive?(emitter)
    end

    test "WHEN the source subscription fails THEN an informative error is raised" do
      assert_raise ArgumentError, ~r/failed to subscribe notifier stream source: :boom/, fn ->
        FailingNotifierSource
        |> AshGrpc.NotifierStream.stream([])
        |> Enum.take(1)
      end
    end

    test "WHEN a notifier payload arrives THEN it is streamed through the server-stream transport" do
      test_pid = self()

      materializer = %{
        __interface__: %{
          send_reply: fn stream, reply, _opts ->
            send(test_pid, {:grpc_reply, reply})
            stream
          end
        }
      }

      request = %NotifierStreamRequest{
        user_id: "grpc-stream-user",
        limit: 1,
        subscribed_ack: test_pid
      }

      task =
        Task.async(fn ->
          AshGrpc.Transport.handle_server_stream(
            NotifierStreamDesk,
            :stream_sync,
            request,
            materializer
          )
        end)

      assert_receive {:stream_subscribed, topic}

      Phoenix.PubSub.broadcast(
        AshGrpc.TestPubSub,
        topic,
        %Phoenix.Socket.Broadcast{
          topic: topic,
          event: "sync",
          payload: %{action: :update, resource: "SupportTicket", data: [%{id: "ticket-1"}]}
        }
      )

      assert_receive {:grpc_reply,
                      %NotifierStreamReply{
                        action: :update,
                        resource: "SupportTicket",
                        record_count: 1
                      }}

      assert :ok = Task.await(task)
    end
  end
end
