defmodule AshGrpc.PrimaryKeyWireTypesTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Stamps.Event
  alias AshGrpc.TestSupport.Stamps.Level
  alias AshGrpc.TestSupport.StampsEndpoint
  alias AshGrpc.TestSupport.StampsEndpoint.Stamps.V1
  alias AshGrpc.TestSupport.StampsEndpoint.Stamps.V1.Stamps.Stub
  alias Google.Protobuf.Timestamp

  setup do
    %{channel: start(StampsEndpoint), metadata: signed_in("anyone")}
  end

  test "a record is fetched and updated by a timestamp key", %{
    channel: channel,
    metadata: metadata
  } do
    at = DateTime.from_unix!(1_700_000_000 + System.unique_integer([:positive]))
    Ash.Seed.seed!(Event, %{at: at, label: "before"})
    key = %Timestamp{seconds: DateTime.to_unix(at), nanos: 0}

    assert {:ok, %{result: %{label: "before"}}} =
             Stub.get_event(channel, %V1.GetEventRequest{at: key}, metadata: metadata)

    assert {:ok, %{result: %{label: "after"}}} =
             Stub.update_event(channel, %V1.UpdateEventRequest{at: key, label: "after"},
               metadata: metadata
             )
  end

  test "a record is fetched and updated by an enum key", %{channel: channel, metadata: metadata} do
    Ash.Seed.seed!(Level, %{rank: :high, label: "before"})

    assert {:ok, %{result: %{label: "before"}}} =
             Stub.get_level(channel, %V1.GetLevelRequest{rank: :GET_LEVEL_REQUEST_RANK_HIGH},
               metadata: metadata
             )

    assert {:ok, %{result: %{label: "after"}}} =
             Stub.update_level(
               channel,
               %V1.UpdateLevelRequest{rank: :UPDATE_LEVEL_REQUEST_RANK_HIGH, label: "after"},
               metadata: metadata
             )
  end

  test "records are destroyed in bulk by timestamp keys", %{channel: channel, metadata: metadata} do
    first = DateTime.from_unix!(1_800_000_000 + System.unique_integer([:positive]))
    second = DateTime.add(first, 1)
    for at <- [first, second], do: Ash.Seed.seed!(Event, %{at: at, label: "doomed"})
    keys = for at <- [first, second], do: %Timestamp{seconds: DateTime.to_unix(at), nanos: 0}

    assert {:ok, %{succeeded: 2}} =
             Stub.delete_events(channel, %V1.DeleteEventsRequest{ids: keys}, metadata: metadata)
  end
end
