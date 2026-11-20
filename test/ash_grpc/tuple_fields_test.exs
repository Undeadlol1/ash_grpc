defmodule AshGrpc.TupleFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Spot
  alias AshGrpc.TestSupport.SpotsEndpoint
  alias AshGrpc.TestSupport.SpotsEndpoint.Spots.V1
  alias AshGrpc.TestSupport.SpotsEndpoint.Spots.V1.Spots.Stub
  alias AshGrpc.Types
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status

  @fields [
    x: [type: :integer, allow_nil?: false],
    y: [type: :integer, constraints: [max: 100]],
    note: [type: :string]
  ]

  describe "kinds" do
    test "a tuple is an unnamed message numbered in declaration order" do
      assert {:ok, {:tuple, nil, [x, y, note]}} = Types.kind(:tuple, fields: @fields)
      assert {x.name, x.number, x.kind, x.optional?} == {:x, 1, :int64, false}
      assert {y.name, y.number, y.optional?} == {:y, 2, true}
      assert {note.name, note.number, note.kind} == {:note, 3, :string}
    end

    test "an array of tuples is a repeated tuple" do
      assert {:ok, {:array, {:tuple, nil, [_x, _y, _note]}}} =
               Types.kind({:array, :tuple}, items: [fields: @fields])
    end

    test "a tuple without fields is rejected" do
      assert {:error, reason} = Types.kind(:tuple)
      assert reason =~ "tuple without `fields` constraints"
    end

    test "a tuple holding an unmapped type is rejected naming the field" do
      assert {:error, reason} = Types.kind(:tuple, fields: [blob: [type: :term]])
      assert reason =~ "has a field :blob"
    end
  end

  describe "proto" do
    setup do
      [{_path, text}] = AshGrpc.Proto.render(SpotsEndpoint)
      %{text: text}
    end

    test "a tuple field is a message named after the parent and the field", %{text: text} do
      assert text =~ "  SpotPoint point = 2;"
      assert text =~ "  repeated SpotPoints points = 3;"

      assert text =~
               "message SpotPoint {\n  int64 x = 1;\n  optional int64 y = 2;\n  optional string note = 3;\n}"
    end

    test "a tuple argument and a tuple result are named after the request and the rpc", %{
      text: text
    } do
      assert text =~ "message MirrorPointRequest {\n  MirrorPointRequestAt at = 1;\n}"
      assert text =~ "message MirrorPointRequestAt {\n  int64 x = 1;"
      assert text =~ "message MirrorPointResponse {\n  MirrorPointResult result = 1;\n}"
      assert text =~ "message MirrorPointResult {\n  int64 x = 1;"
    end

    test "reordering the elements of a tuple is a breaking change", %{text: text} do
      reordered =
        String.replace(
          text,
          "  int64 x = 1;\n  optional int64 y = 2;\n  optional string note = 3;\n}\n\nmessage SpotPoints",
          "  optional int64 y = 1;\n  int64 x = 2;\n  optional string note = 3;\n}\n\nmessage SpotPoints"
        )

      assert reordered != text
      assert [change | _] = AshGrpc.Proto.Compatibility.check(text, reordered)
      assert change =~ "message SpotPoint: field 1 changed"
    end
  end

  describe "over a real connection" do
    setup do
      %{channel: start(SpotsEndpoint), metadata: signed_in("someone")}
    end

    defp create!(channel, metadata, request) do
      assert {:ok, %{result: spot}} = Stub.create_spot(channel, request, metadata: metadata)
      spot
    end

    test "a tuple and an array of tuples round trip through a create", %{
      channel: channel,
      metadata: metadata
    } do
      spot =
        create!(channel, metadata, %V1.CreateSpotRequest{
          point: %V1.SpotPoint{x: 1, y: 2, note: "a"},
          points: [%V1.SpotPoints{x: 3}, %V1.SpotPoints{x: 4, y: 5, note: "b"}]
        })

      assert spot.point == %V1.SpotPoint{x: 1, y: 2, note: "a"}
      assert spot.points == [%V1.SpotPoints{x: 3}, %V1.SpotPoints{x: 4, y: 5, note: "b"}]
    end

    test "the stored value is an Elixir tuple in field order", %{
      channel: channel,
      metadata: metadata
    } do
      spot =
        create!(channel, metadata, %V1.CreateSpotRequest{
          point: %V1.SpotPoint{x: 1, y: 2, note: "a"},
          points: [%V1.SpotPoints{x: 3}]
        })

      stored = Ash.get!(Spot, spot.id, authorize?: false)
      assert stored.point == {1, 2, "a"}
      assert stored.points == [{3, nil, nil}]
    end

    test "an unset tuple is unset and an unset array of tuples is empty", %{
      channel: channel,
      metadata: metadata
    } do
      spot = create!(channel, metadata, %V1.CreateSpotRequest{})
      assert {spot.point, spot.points} == {nil, []}
    end

    test "an update replaces a tuple", %{channel: channel, metadata: metadata} do
      spot = create!(channel, metadata, %V1.CreateSpotRequest{point: %V1.SpotPoint{x: 1}})
      request = %V1.UpdateSpotRequest{id: spot.id, point: %V1.SpotPoint{x: 9, y: 8}}

      assert {:ok, %{result: updated}} = Stub.update_spot(channel, request, metadata: metadata)
      assert updated.point == %V1.SpotPoint{x: 9, y: 8}
    end

    test "a tuple argument reaches the action and a tuple result comes back", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.MirrorPointRequest{at: %V1.MirrorPointRequestAt{x: 7, note: "n"}}

      assert {:ok, %{result: result}} = Stub.mirror_point(channel, request, metadata: metadata)
      assert result == %V1.MirrorPointResult{x: 7, note: "n"}
    end

    test "a tuple element out of bounds is INVALID_ARGUMENT naming the field", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.CreateSpotRequest{point: %V1.SpotPoint{x: 1, y: 101}}

      assert {:error, %RPCError{status: status, details: [detail | _]}} =
               Stub.create_spot(channel, request, metadata: metadata)

      assert status == Status.invalid_argument()
      assert %BadRequest{field_violations: [violation]} = BadRequest.decode(detail.value)
      assert violation.field == "point.y"
    end
  end
end
