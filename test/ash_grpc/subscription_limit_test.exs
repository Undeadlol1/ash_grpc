defmodule AshGrpc.SubscriptionLimitTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.CappedNotesEndpoint
  alias AshGrpc.TestSupport.CappedNotesEndpoint.Notes.V1
  alias AshGrpc.TestSupport.CappedNotesEndpoint.Notes.V1.Notes.Stub
  alias GRPC.RPCError
  alias GRPC.Status

  defp watch(channel, author) do
    test = self()

    spawn_link(fn ->
      case Stub.watch_notes(channel, %V1.WatchNotesRequest{},
             metadata: signed_in(author),
             timeout: 5_000
           ) do
        {:ok, replies} -> Enum.each(replies, &send(test, {:reply, &1}))
        error -> send(test, {:reply, error})
      end
    end)
  end

  defp open_streams,
    do: length(:pg.get_local_members(AshGrpc.Notifier, {:subscriptions, CappedNotesEndpoint}))

  defp wait_until_open(count, attempts \\ 100) do
    cond do
      open_streams() == count -> :ok
      attempts == 0 -> flunk("expected #{count} open streams, found #{open_streams()}")
      true -> Process.sleep(10) && wait_until_open(count, attempts - 1)
    end
  end

  test "an endpoint refuses subscriptions beyond max_subscriptions with RESOURCE_EXHAUSTED" do
    channel = start(CappedNotesEndpoint)
    author = "author#{System.unique_integer([:positive])}"

    for _stream <- 1..2 do
      watch(channel, author)
      assert_receive {:reply, {:ok, %{synced: true}}}, 2_000
    end

    watch(channel, author)
    assert_receive {:reply, {:error, %RPCError{status: status}}}, 2_000
    assert status == Status.resource_exhausted()
    wait_until_open(2)
  end

  test "a closed stream frees its place" do
    full = start(CappedNotesEndpoint)
    author = "author#{System.unique_integer([:positive])}"
    port = :ranch.get_port(inspect(CappedNotesEndpoint))
    {:ok, leaving} = GRPC.Stub.connect("127.0.0.1:#{port}")

    watch(leaving, author)
    assert_receive {:reply, {:ok, %{synced: true}}}, 2_000
    watch(full, author)
    assert_receive {:reply, {:ok, %{synced: true}}}, 2_000
    GRPC.Stub.disconnect(leaving)
    wait_until_open(1)

    watch(full, author)
    assert_receive {:reply, {:ok, %{synced: true}}}, 2_000
  end
end
