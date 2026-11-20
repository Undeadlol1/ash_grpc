defmodule AshGrpc.BidirectionalStreamingTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer
  import ExUnit.CaptureLog

  alias AshGrpc.Status, as: RpcStatus
  alias AshGrpc.TestSupport.StreamEndpoint
  alias AshGrpc.TestSupport.StreamEndpoint.Stream.V1
  alias AshGrpc.TestSupport.StreamEntry, as: Entry
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status
  alias V1.Entries.Stub

  setup do
    %{
      channel: start(StreamEndpoint),
      owner: "owner#{System.unique_integer([:positive])}"
    }
  end

  defp open(ctx, rpc), do: apply(Stub, rpc, [ctx.channel, [metadata: signed_in(ctx.owner)]])

  defp post(stream, title),
    do: GRPC.Stub.send_request(stream, %V1.PostEntriesRequest{title: title})

  defp replies(stream) do
    {:ok, replies} = GRPC.Stub.recv(stream)
    replies
  end

  defp entry(owner, title), do: Ash.Seed.seed!(Entry, %{title: title, owner: owner})

  defp titles(owner),
    do: Entry |> Ash.read!(actor: %{name: owner}) |> Enum.map(& &1.title) |> Enum.sort()

  defp violations(%RpcStatus{details: [detail | _]}),
    do: BadRequest.decode(detail.value).field_violations

  defp posted_in_one_go(ctx, titles) do
    stream = open(ctx, :post_entries)
    Enum.each(titles, &post(stream, &1))
    GRPC.Stub.end_stream(stream)
    stream |> replies() |> Enum.to_list()
  end

  test "every message gets its own reply, in order, and a bad one does not stop the stream",
       ctx do
    assert [{:ok, first}, {:ok, second}, {:ok, third}] =
             posted_in_one_go(ctx, ["first", "no", "third"])

    assert %V1.PostEntriesReply{
             index: 0,
             outcome: {:result, %V1.PostEntriesResponse{result: %V1.Entry{title: "first"}}}
           } =
             first

    assert %V1.PostEntriesReply{index: 1, outcome: {:error, %RpcStatus{code: code} = status}} =
             second

    assert code == Status.invalid_argument()
    assert [%{field: "title"}] = violations(status)

    assert %V1.PostEntriesReply{
             index: 2,
             outcome: {:result, %V1.PostEntriesResponse{result: %V1.Entry{title: "third"}}}
           } =
             third

    assert titles(ctx.owner) == ["first", "third"]
  end

  test "a reply arrives before the client has sent the next message", ctx do
    stream = open(ctx, :post_entries)

    post(stream, "first")
    replies = replies(stream)
    assert [{:ok, %V1.PostEntriesReply{index: 0, outcome: {:result, _}}}] = Enum.take(replies, 1)
    assert titles(ctx.owner) == ["first"]

    post(stream, "second")
    assert [{:ok, %V1.PostEntriesReply{index: 1, outcome: {:result, _}}}] = Enum.take(replies, 1)

    GRPC.Stub.end_stream(stream)
    assert Enum.to_list(replies) == []
  end

  test "a stream that sends nothing ends with no replies", ctx do
    stream = open(ctx, :post_entries)
    GRPC.Stub.end_stream(stream)

    assert stream |> replies() |> Enum.to_list() == []
  end

  test "an update finds each record by its key", ctx do
    existing = entry(ctx.owner, "old title")
    missing = Ash.UUID.generate()
    stream = open(ctx, :retitle_entries)

    GRPC.Stub.send_request(stream, %V1.RetitleEntriesRequest{id: existing.id, title: "new title"})
    GRPC.Stub.send_request(stream, %V1.RetitleEntriesRequest{id: missing, title: "other title"})
    GRPC.Stub.end_stream(stream)

    assert [{:ok, updated}, {:ok, absent}] = stream |> replies() |> Enum.to_list()

    assert %{index: 0, outcome: {:result, %{result: %V1.Entry{id: id, title: "new title"}}}} =
             updated

    assert id == existing.id
    assert %{index: 1, outcome: {:error, %RpcStatus{code: code}}} = absent
    assert code == Status.not_found()
  end

  test "a read answers one record per message", ctx do
    existing = entry(ctx.owner, "findable")
    stream = open(ctx, :find_entries)

    GRPC.Stub.send_request(stream, %V1.FindEntriesRequest{id: Ash.UUID.generate()})
    GRPC.Stub.send_request(stream, %V1.FindEntriesRequest{id: existing.id})
    GRPC.Stub.end_stream(stream)

    assert [{:ok, absent}, {:ok, found}] = stream |> replies() |> Enum.to_list()
    assert %{index: 0, outcome: {:error, %RpcStatus{code: code}}} = absent
    assert code == Status.not_found()
    assert %{index: 1, outcome: {:result, %{result: %V1.Entry{title: "findable"}}}} = found
  end

  test "a policy refusal is reported for that message only", ctx do
    assert [{:ok, first}, {:ok, refused}, {:ok, last}] =
             posted_in_one_go(ctx, ["fine", "classified", "fine too"])

    assert %{index: 0, outcome: {:result, _}} = first
    assert %{index: 1, outcome: {:error, %RpcStatus{code: code, message: "Forbidden"}}} = refused
    assert code == Status.permission_denied()
    assert %{index: 2, outcome: {:result, _}} = last
    assert titles(ctx.owner) == ["fine", "fine too"]
  end

  test "an unauthenticated stream is refused once and nothing is processed", ctx do
    title = "refused#{System.unique_integer([:positive])}"
    stream = Stub.post_entries(ctx.channel, metadata: %{})
    post(stream, title)
    post(stream, title <> "again")
    GRPC.Stub.end_stream(stream)

    refusals =
      case GRPC.Stub.recv(stream) do
        {:ok, replies} -> Enum.to_list(replies)
        {:error, error} -> [{:error, error}]
      end

    unauthenticated = Status.unauthenticated()
    assert [{:error, %RPCError{status: ^unauthenticated}}] = refusals
    refute Enum.any?(Ash.read!(Entry, authorize?: false), &String.starts_with?(&1.title, title))
  end

  test "an unexpected exception is reported as INTERNAL without its text and the stream goes on",
       ctx do
    log =
      capture_log(fn ->
        stream = open(ctx, :explode_entries)
        GRPC.Stub.send_request(stream, %V1.ExplodeEntriesRequest{})
        GRPC.Stub.send_request(stream, %V1.ExplodeEntriesRequest{})
        GRPC.Stub.end_stream(stream)

        assert [{:ok, first}, {:ok, second}] = stream |> replies() |> Enum.to_list()

        for {reply, index} <- [{first, 0}, {second, 1}] do
          assert %{
                   index: ^index,
                   outcome: {:error, %RpcStatus{code: code, message: "Internal error"} = status}
                 } = reply

          assert code == Status.internal()
          refute inspect(status) =~ "secret"
        end
      end)

    assert log =~ "secret internal detail"
  end
end
