defmodule AshGrpc.ArrayFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Parcel
  alias AshGrpc.TestSupport.ParcelsEndpoint
  alias AshGrpc.TestSupport.ParcelsEndpoint.Parcels.V1
  alias AshGrpc.TestSupport.ParcelsEndpoint.Parcels.V1.Parcels.Stub
  alias AshGrpc.Types
  alias Google.Protobuf.Struct
  alias Google.Protobuf.Timestamp
  alias Google.Protobuf.Value
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status

  describe "kinds" do
    test "an array of a mapped type is an array of its kind" do
      assert Types.kind({:array, :string}) == {:ok, {:array, :string}}

      assert {:ok, {:array, {:enum, %{name: "Mood"}}}} =
               Types.kind({:array, AshGrpc.TestSupport.Mood})

      assert Types.kind({:array, :map}) == {:ok, {:array, :struct}}
    end

    test "an array that allows nil items is rejected" do
      assert {:error, reason} = Types.kind({:array, :string}, nil_items?: true)
      assert reason =~ "nil items"
    end

    test "an array of an unmapped type is rejected with the item's reason" do
      assert {:error, reason} = Types.kind({:array, :term})
      assert reason =~ "any term"
    end
  end

  describe "proto" do
    test "arrays are repeated and never optional, in resources and requests" do
      [{_path, text}] = AshGrpc.Proto.render(ParcelsEndpoint)

      assert text =~ "  repeated string tags = 9;"
      assert text =~ "  repeated Mood moods = 10;"
      assert text =~ "  repeated int64 scores = 11;"
      assert text =~ "  repeated google.protobuf.Timestamp stamps = 12;"
      assert text =~ "  repeated google.protobuf.Struct blobs = 14;"
      assert text =~ "  repeated string days = 15;"
      assert text =~ "  repeated string tags = 8;"
      assert text =~ "  repeated string labels = 4;"
      refute text =~ "optional repeated"
    end
  end

  describe "over a real connection" do
    setup do
      %{channel: start(ParcelsEndpoint), metadata: signed_in("someone")}
    end

    defp blob, do: %Struct{fields: %{"size" => %Value{kind: {:number_value, 2.0}}}}

    defp stamp, do: %Timestamp{seconds: DateTime.to_unix(~U[2026-11-12 09:00:00Z]), nanos: 5000}

    defp create!(channel, metadata, request) do
      assert {:ok, %{result: parcel}} = Stub.create_parcel(channel, request, metadata: metadata)
      parcel
    end

    test "arrays round trip through a create", %{channel: channel, metadata: metadata} do
      parcel =
        create!(channel, metadata, %V1.CreateParcelRequest{
          tags: ["fragile", "heavy"],
          moods: [:MOOD_CALM, :MOOD_WILD],
          scores: [3, 1, 2],
          stamps: [stamp()],
          tiers: [:TIER_PRO],
          blobs: [blob()],
          days: ["2026-11-12"]
        })

      assert parcel.tags == ["fragile", "heavy"]
      assert parcel.moods == [:MOOD_CALM, :MOOD_WILD]
      assert parcel.scores == [3, 1, 2]
      assert parcel.stamps == [stamp()]
      assert parcel.tiers == [:TIER_PRO]
      assert parcel.blobs == [blob()]
      assert parcel.days == ["2026-11-12"]

      assert %Parcel{moods: [:calm, :wild], days: [~D[2026-11-12]], blobs: [%{"size" => 2}]} =
               Ash.get!(Parcel, parcel.id, authorize?: false)
    end

    test "an array argument reaches the action", %{channel: channel, metadata: metadata} do
      assert {:ok, %{result: parcel}} =
               Stub.pack_parcel(channel, %V1.PackParcelRequest{labels: ["a", "b"]},
                 metadata: metadata
               )

      assert parcel.tags == ["a", "b"]
    end

    test "an empty array is not sent, so the attribute keeps its value", %{
      channel: channel,
      metadata: metadata
    } do
      parcel = create!(channel, metadata, %V1.CreateParcelRequest{tags: ["kept"], scores: [9]})

      assert {:ok, %{result: updated}} =
               Stub.update_parcel(channel, %V1.UpdateParcelRequest{id: parcel.id, tags: []},
                 metadata: metadata
               )

      assert updated.tags == ["kept"]
      assert updated.scores == [9]
    end

    test "clear_fields sets an array to nil, which is sent as empty", %{
      channel: channel,
      metadata: metadata
    } do
      parcel = create!(channel, metadata, %V1.CreateParcelRequest{tags: ["gone"]})

      assert {:ok, %{result: updated}} =
               Stub.update_parcel(
                 channel,
                 %V1.UpdateParcelRequest{id: parcel.id, clear_fields: ["tags"]},
                 metadata: metadata
               )

      assert updated.tags == []
      assert %Parcel{tags: nil} = Ash.get!(Parcel, parcel.id, authorize?: false)
    end

    test "an unset array of a required attribute takes its default", %{
      channel: channel,
      metadata: metadata
    } do
      parcel = create!(channel, metadata, %V1.CreateParcelRequest{})

      assert {parcel.tags, parcel.scores} == {[], []}
    end

    test "an invalid item is INVALID_ARGUMENT naming the field", %{
      channel: channel,
      metadata: metadata
    } do
      assert {:error, %RPCError{status: status, details: [detail | _]}} =
               Stub.create_parcel(channel, %V1.CreateParcelRequest{moods: [:MOOD_CALM, 99]},
                 metadata: metadata
               )

      assert status == Status.invalid_argument()
      assert %BadRequest{field_violations: [%{field: "moods"}]} = BadRequest.decode(detail.value)
    end

    test "a malformed timestamp item is INVALID_ARGUMENT naming the field", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.CreateParcelRequest{stamps: [stamp(), %Timestamp{seconds: 0, nanos: -1}]}

      assert {:error, %RPCError{status: status, details: [detail | _]}} =
               Stub.create_parcel(channel, request, metadata: metadata)

      assert status == Status.invalid_argument()
      assert %BadRequest{field_violations: [%{field: "stamps"}]} = BadRequest.decode(detail.value)
    end

    test "a subscription sends arrays", %{channel: channel, metadata: metadata} do
      parcel = create!(channel, metadata, %V1.CreateParcelRequest{tags: ["watched"], scores: [4]})

      assert {:ok, replies} =
               Stub.watch_parcels(channel, %V1.WatchParcelsRequest{},
                 metadata: metadata,
                 timeout: 500
               )

      watched =
        replies
        |> Enum.take_while(&match?({:ok, %{synced: false}}, &1))
        |> Enum.map(fn {:ok, reply} -> reply.result end)
        |> Enum.find(&(&1.id == parcel.id))

      assert {watched.tags, watched.scores} == {["watched"], [4]}
    end
  end
end
