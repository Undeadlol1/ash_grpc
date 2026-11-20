defmodule AshGrpc.ClientStreamingTest do
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

  defp import_titles(ctx, rpc, titles) do
    stream = apply(Stub, rpc, [ctx.channel, [metadata: signed_in(ctx.owner)]])
    Enum.each(titles, &GRPC.Stub.send_request(stream, %V1.ImportEntriesRequest{title: &1}))
    GRPC.Stub.end_stream(stream)
    GRPC.Stub.recv(stream)
  end

  defp titles(owner),
    do: Entry |> Ash.read!(actor: %{name: owner}) |> Enum.map(& &1.title) |> Enum.sort()

  defp violations(%RpcStatus{details: [detail | _]}),
    do: BadRequest.decode(detail.value).field_violations

  test "answers one summary with the count saved and the messages that failed", ctx do
    assert {:ok, %V1.ImportEntriesSummary{succeeded: 3, failures: [first, second]}} =
             import_titles(ctx, :import_entries, ["one", "no", "three", "x", "five"])

    assert %V1.ImportEntriesFailure{index: 1, error: %RpcStatus{code: code} = status} = first
    assert code == Status.invalid_argument()
    assert [%{field: "title"}] = violations(status)
    assert %V1.ImportEntriesFailure{index: 3, error: %RpcStatus{code: ^code}} = second
    assert titles(ctx.owner) == ["five", "one", "three"]
  end

  test "an empty stream answers a summary of nothing", ctx do
    assert {:ok, %V1.ImportEntriesSummary{succeeded: 0, failures: []}} =
             import_titles(ctx, :import_entries, [])
  end

  test "more failures than max_stream_failures ends the call and keeps what was saved", ctx do
    assert {:error, %RPCError{status: status}} =
             import_titles(ctx, :import_few_entries, ["good", "no", "x", "y", "never saved"])

    assert status == Status.resource_exhausted()
    assert titles(ctx.owner) == ["good"]
  end

  test "failures up to max_stream_failures are still summarised", ctx do
    assert {:ok, %V1.ImportFewEntriesSummary{succeeded: 1, failures: [_, _]}} =
             import_titles(ctx, :import_few_entries, ["good", "no", "x"])
  end

  test "an unexpected exception is a failure of that message, without its text", ctx do
    log =
      capture_log(fn ->
        stream = Stub.explode_import(ctx.channel, metadata: signed_in(ctx.owner))
        GRPC.Stub.send_request(stream, %V1.ExplodeImportRequest{})
        GRPC.Stub.end_stream(stream)

        assert {:ok, %V1.ExplodeImportSummary{succeeded: 0, failures: [failure]}} =
                 GRPC.Stub.recv(stream)

        assert %{index: 0, error: %RpcStatus{code: code, message: "Internal error"} = status} =
                 failure

        assert code == Status.internal()
        refute inspect(status) =~ "secret"
      end)

    assert log =~ "secret internal detail"
  end

  test "an unauthenticated stream is refused and nothing is saved", ctx do
    stream = Stub.import_entries(ctx.channel, metadata: %{})
    GRPC.Stub.send_request(stream, %V1.ImportEntriesRequest{title: "refused entry"})
    GRPC.Stub.end_stream(stream)

    assert {:error, %RPCError{status: status}} = GRPC.Stub.recv(stream)
    assert status == Status.unauthenticated()
    refute Enum.any?(Ash.read!(Entry, authorize?: false), &(&1.title == "refused entry"))
  end
end
