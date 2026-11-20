defmodule AshGrpc.NestedArrayFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Mood
  alias AshGrpc.TestSupport.Spot
  alias AshGrpc.TestSupport.SpotsEndpoint
  alias AshGrpc.TestSupport.SpotsEndpoint.Spots.V1
  alias AshGrpc.TestSupport.SpotsEndpoint.Spots.V1.Spots.Stub
  alias AshGrpc.Types
  alias Spark.Error.DslError

  describe "kinds" do
    test "an array of arrays is an array of a wrapped kind" do
      assert Types.kind({:array, {:array, :string}}) == {:ok, {:array, {:wrapper, :string}}}
    end

    test "every level of nesting wraps once" do
      assert Types.kind({:array, {:array, {:array, :integer}}}) ==
               {:ok, {:array, {:wrapper, {:wrapper, :int64}}}}
    end

    test "the item may be an enum" do
      assert {:ok, {:array, {:wrapper, {:enum, %{name: "Mood"}}}}} =
               Types.kind({:array, {:array, Mood}})
    end

    test "an array whose items are arrays that allow nil items is rejected" do
      assert {:error, reason} = Types.kind({:array, {:array, :string}}, items: [nil_items?: true])
      assert reason =~ "nil items"
    end

    test "an array of arrays that allows nil items is rejected" do
      assert {:error, reason} = Types.kind({:array, {:array, :string}}, nil_items?: true)
      assert reason =~ "nil items"
    end

    test "an array of arrays of an unmapped type is rejected with the item's reason" do
      assert {:error, reason} = Types.kind({:array, {:array, :term}})
      assert reason =~ "any term"
    end

    test "a resource field holding an array of arrays that allow nil items does not compile" do
      assert_raise DslError, ~r/Field :grid has type .* nil items/, fn ->
        compile_resource("""
        grpc do
          proto_message "Grid"
          fields id: 1, grid: 2
        end

        attributes do
          uuid_primary_key :id, public?: true
          attribute :grid, {:array, {:array, :integer}}, public?: true, constraints: [items: [nil_items?: true]]
        end
        """)
      end
    end
  end

  describe "proto" do
    setup do
      [{_path, text}] = AshGrpc.Proto.render(SpotsEndpoint)
      %{text: text}
    end

    test "the outer field repeats a wrapper holding the inner list", %{text: text} do
      assert text =~ "  repeated SpotGridItem grid = 4;"
      assert text =~ "message SpotGridItem {\n  repeated int64 values = 1;\n}"
    end

    test "each level of nesting adds a wrapper named by the same rule", %{text: text} do
      assert text =~ "  repeated SpotCubeItem cube = 5;"
      assert text =~ "message SpotCubeItem {\n  repeated SpotCubeItemValuesItem values = 1;\n}"
      assert text =~ "message SpotCubeItemValuesItem {\n  repeated string values = 1;\n}"
    end

    test "the item may be an enum or a tuple", %{text: text} do
      assert text =~ "message SpotMoodsItem {\n  repeated Mood values = 1;\n}"
      assert text =~ "message SpotLanesItem {\n  repeated SpotLanesItemValues values = 1;\n}"
      assert text =~ "message SpotLanesItemValues {\n  int64 x = 1;"
    end

    test "an argument and a result are wrapped too", %{text: text} do
      assert text =~
               "message MirrorGridRequest {\n  repeated MirrorGridRequestRowsItem rows = 1;\n}"

      assert text =~
               "message MirrorGridResponse {\n  repeated MirrorGridResultItem result = 1;\n}"

      assert text =~ "message MirrorGridResultItem {\n  repeated int64 values = 1;\n}"
    end
  end

  describe "compile errors" do
    test "a wrapper named like another message with other fields is rejected" do
      clashing = "AshGrpc.Compiled.Clash#{System.unique_integer([:positive])}.BoxGridItem"

      compile(
        "defmodule #{clashing} do\n use Ash.TypedStruct\n typed_struct do\n field :width, :integer\n end\n end"
      )

      domain =
        compile_domain(
          ~s(package "boxes.v1"\nservice "Boxes" do\n rpc INLINE, :list_boxes, :read, sort: false, filter: false, page: false\n end),
          """
          grpc do
            proto_message "Box"
            fields id: 1, grid: 2, other: 3
          end

          actions do
            defaults [:read]
          end

          attributes do
            uuid_primary_key :id, public?: true
            attribute :grid, {:array, {:array, :integer}}, public?: true
            attribute :other, #{clashing}, public?: true
          end
          """
        )

      assert_raise DslError, ~r/"BoxGridItem" is defined more than once/, fn ->
        AshGrpc.Schema.build([domain])
      end
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

    defp ints(values), do: %V1.SpotGridItem{values: values}

    test "an array of arrays round trips and is stored as nested lists", %{
      channel: channel,
      metadata: metadata
    } do
      spot = create!(channel, metadata, %V1.CreateSpotRequest{grid: [ints([1, 2]), ints([3])]})

      assert spot.grid == [ints([1, 2]), ints([3])]
      assert Ash.get!(Spot, spot.id, authorize?: false).grid == [[1, 2], [3]]
    end

    test "an empty inner list survives", %{channel: channel, metadata: metadata} do
      spot =
        create!(channel, metadata, %V1.CreateSpotRequest{grid: [ints([1]), ints([]), ints([2])]})

      assert spot.grid == [ints([1]), ints([]), ints([2])]
      assert Ash.get!(Spot, spot.id, authorize?: false).grid == [[1], [], [2]]
    end

    test "an unset array of arrays is empty", %{channel: channel, metadata: metadata} do
      spot = create!(channel, metadata, %V1.CreateSpotRequest{})
      assert {spot.grid, spot.cube} == {[], []}
    end

    test "three levels of nesting round trip", %{channel: channel, metadata: metadata} do
      cube = [
        %V1.SpotCubeItem{
          values: [
            %V1.SpotCubeItemValuesItem{values: ["a", "b"]},
            %V1.SpotCubeItemValuesItem{values: []}
          ]
        },
        %V1.SpotCubeItem{values: [%V1.SpotCubeItemValuesItem{values: ["c"]}]}
      ]

      spot = create!(channel, metadata, %V1.CreateSpotRequest{cube: cube})

      assert spot.cube == cube
      assert Ash.get!(Spot, spot.id, authorize?: false).cube == [[["a", "b"], []], [["c"]]]
    end

    test "arrays of arrays of enums round trip", %{channel: channel, metadata: metadata} do
      moods = [
        %V1.SpotMoodsItem{values: [:MOOD_CALM, :MOOD_WILD]},
        %V1.SpotMoodsItem{values: [:MOOD_WILD]}
      ]

      spot = create!(channel, metadata, %V1.CreateSpotRequest{moods: moods})

      assert spot.moods == moods
      assert Ash.get!(Spot, spot.id, authorize?: false).moods == [[:calm, :wild], [:wild]]
    end

    test "arrays of arrays of tuples round trip", %{channel: channel, metadata: metadata} do
      lanes = [
        %V1.SpotLanesItem{
          values: [%V1.SpotLanesItemValues{x: 1, y: 2}, %V1.SpotLanesItemValues{x: 3}]
        },
        %V1.SpotLanesItem{values: []}
      ]

      spot = create!(channel, metadata, %V1.CreateSpotRequest{lanes: lanes})

      assert spot.lanes == lanes

      assert Ash.get!(Spot, spot.id, authorize?: false).lanes == [
               [{1, 2, nil}, {3, nil, nil}],
               []
             ]
    end

    test "an array of arrays argument reaches the action and comes back", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.MirrorGridRequest{
        rows: [
          %V1.MirrorGridRequestRowsItem{values: [4, 5]},
          %V1.MirrorGridRequestRowsItem{values: [6]}
        ]
      }

      assert {:ok, %{result: result}} = Stub.mirror_grid(channel, request, metadata: metadata)

      assert result == [
               %V1.MirrorGridResultItem{values: [4, 5]},
               %V1.MirrorGridResultItem{values: [6]}
             ]
    end

    test "a three level argument comes back as a three level result", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.MirrorCubeRequest{
        cells: [
          %V1.MirrorCubeRequestCellsItem{
            values: [%V1.MirrorCubeRequestCellsItemValuesItem{values: ["x", "y"]}]
          }
        ]
      }

      assert {:ok, %{result: [outer]}} = Stub.mirror_cube(channel, request, metadata: metadata)
      assert [%{values: ["x", "y"]}] = outer.values
    end
  end
end
