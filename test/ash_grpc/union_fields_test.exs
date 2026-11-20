defmodule AshGrpc.UnionFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.Proto.Compatibility
  alias AshGrpc.TestSupport.Figure
  alias AshGrpc.TestSupport.FiguresEndpoint
  alias AshGrpc.TestSupport.FiguresEndpoint.Figures.V1
  alias AshGrpc.TestSupport.FiguresEndpoint.Figures.V1.Figures.Stub
  alias AshGrpc.TestSupport.Remark
  alias AshGrpc.Types
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status
  alias Spark.Error.DslError

  describe "kinds" do
    test "a union is a message of members numbered in declaration order" do
      constraints = [types: [text: [type: :string], count: [type: :integer]]]

      assert {:ok, {:union, nil, [text, count]}} = Types.kind(:union, constraints)
      assert {text.name, text.number, text.kind} == {:text, 1, :string}
      assert {count.name, count.number, count.kind} == {:count, 2, :int64}
    end

    test "an array of unions is a repeated union" do
      constraints = [items: [types: [text: [type: :string]]]]

      assert {:ok, {:array, {:union, nil, [_text]}}} = Types.kind({:array, :union}, constraints)
    end

    test "a new type of a union is named after its module" do
      assert {:ok, {:union, "Remark", [words, stars]}} = Types.kind(Remark)
      assert {words.name, stars.name} == {:words, :stars}
    end
  end

  describe "proto" do
    setup do
      [{_path, text}] = AshGrpc.Proto.render(FiguresEndpoint)
      %{text: text}
    end

    test "a union field is a message with one oneof", %{text: text} do
      assert text =~ "  FigureMeasure measure = 2;"
      assert text =~ "  repeated FigureShapes shapes = 6;"

      assert text =~
               "message FigureMeasure {\n  oneof value {\n    string text = 1;\n    int64 count = 2;\n    bool flag = 3;\n  }\n}"

      assert text =~ "    Circle circle = 1;\n    Square square = 2;\n    FigureShapeBox box = 3;"

      assert text =~
               "message Remark {\n  oneof value {\n    string words = 1;\n    int64 stars = 2;\n  }\n}"
    end

    test "removing a member is a breaking change", %{text: text} do
      removed = String.replace(text, "    bool flag = 3;\n", "")

      assert [change | _] = Compatibility.check(text, removed)
      assert change =~ "message FigureMeasure: field 3 (`bool flag`) was removed"
    end

    test "renumbering a member is a breaking change", %{text: text} do
      renumbered =
        String.replace(
          text,
          "    string text = 1;\n    int64 count = 2;",
          "    int64 count = 1;\n    string text = 2;"
        )

      assert [change | _] = Compatibility.check(text, renumbered)
      assert change =~ "message FigureMeasure: field 1 changed"
    end

    test "retyping a member is a breaking change", %{text: text} do
      retyped = String.replace(text, "    bool flag = 3;", "    string flag = 3;")

      assert [change | _] = Compatibility.check(text, retyped)
      assert change =~ "message FigureMeasure: field 3 changed"
    end

    test "adding a member is fine", %{text: text} do
      added =
        String.replace(text, "    bool flag = 3;", "    bool flag = 3;\n    double ratio = 4;")

      assert Compatibility.check(text, added) == :ok
    end
  end

  describe "compile errors" do
    test "an array member is rejected naming the member" do
      assert_raise DslError, ~r/Field :choice .* member :tags that is an array/, fn ->
        compile_resource(choice_resource(tags: [type: {:array, :string}]))
      end
    end

    test "an unmappable member is rejected naming the member" do
      assert_raise DslError, ~r/Field :choice .* member :bag that/, fn ->
        compile_resource(choice_resource(bag: [type: :term]))
      end
    end
  end

  describe "over a real connection" do
    setup do
      %{channel: start(FiguresEndpoint), metadata: signed_in("someone")}
    end

    defp create!(channel, metadata, request) do
      assert {:ok, %{result: figure}} = Stub.create_figure(channel, request, metadata: metadata)
      figure
    end

    defp member(type, value), do: {type, value}

    defp measure(type, value), do: %V1.FigureMeasure{value: member(type, value)}

    test "scalar members round trip", %{channel: channel, metadata: metadata} do
      for {type, value} <- [text: "wide", count: 7, flag: false] do
        figure =
          create!(channel, metadata, %V1.CreateFigureRequest{measure: measure(type, value)})

        assert figure.measure == measure(type, value)
      end
    end

    test "an embedded resource member round trips", %{channel: channel, metadata: metadata} do
      figure =
        create!(channel, metadata, %V1.CreateFigureRequest{
          shape: %V1.FigureShape{value: member(:circle, %V1.Circle{radius: 3})}
        })

      assert figure.shape == %V1.FigureShape{value: member(:circle, %V1.Circle{radius: 3})}

      stored = Ash.get!(Figure, figure.id, authorize?: false)
      assert %Ash.Union{type: :circle, value: %{radius: 3}} = stored.shape
    end

    test "a map member with fields round trips", %{channel: channel, metadata: metadata} do
      shape = %V1.FigureShape{value: member(:box, %V1.FigureShapeBox{height: 4})}
      figure = create!(channel, metadata, %V1.CreateFigureRequest{shape: shape})

      assert figure.shape == shape
    end

    test "a tagged union keeps its tag", %{channel: channel, metadata: metadata} do
      pet = %V1.FigurePet{value: member(:cat, %V1.FigurePetCat{kind: "cat", lives: 9})}
      figure = create!(channel, metadata, %V1.CreateFigureRequest{pet: pet})

      assert figure.pet == pet

      stored = Ash.get!(Figure, figure.id, authorize?: false)
      assert %Ash.Union{type: :cat} = stored.pet
    end

    test "a union of a new type round trips", %{channel: channel, metadata: metadata} do
      remark = %V1.Remark{value: member(:stars, 5)}
      figure = create!(channel, metadata, %V1.CreateFigureRequest{remark: remark})

      assert figure.remark == remark
    end

    test "an array of unions round trips in order", %{channel: channel, metadata: metadata} do
      shapes = [
        %V1.FigureShapes{value: member(:square, %V1.Square{side: 2})},
        %V1.FigureShapes{value: member(:circle, %V1.Circle{radius: 1})}
      ]

      figure = create!(channel, metadata, %V1.CreateFigureRequest{shapes: shapes})

      assert figure.shapes == shapes
    end

    test "an unset union is unset", %{channel: channel, metadata: metadata} do
      figure = create!(channel, metadata, %V1.CreateFigureRequest{})

      assert {figure.measure, figure.shape, figure.pet, figure.remark, figure.shapes} ==
               {nil, nil, nil, nil, []}
    end

    test "a union message with no member set is not sent", %{channel: channel, metadata: metadata} do
      figure = create!(channel, metadata, %V1.CreateFigureRequest{measure: %V1.FigureMeasure{}})

      assert figure.measure == nil
    end

    test "a union argument reaches the action", %{channel: channel, metadata: metadata} do
      request = %V1.MeasureFigureRequest{extra: %V1.MeasureFigureRequestExtra{value: {:count, 8}}}

      assert {:ok, %{result: figure}} = Stub.measure_figure(channel, request, metadata: metadata)
      assert figure.measure == measure(:count, 8)
    end

    test "an update replaces a union and clear_fields empties it", %{
      channel: channel,
      metadata: metadata
    } do
      figure = create!(channel, metadata, %V1.CreateFigureRequest{measure: measure(:text, "a")})

      request = %V1.UpdateFigureRequest{id: figure.id, measure: measure(:count, 2)}
      assert {:ok, %{result: updated}} = Stub.update_figure(channel, request, metadata: metadata)
      assert updated.measure == measure(:count, 2)

      request = %V1.UpdateFigureRequest{id: figure.id, clear_fields: ["measure"]}
      assert {:ok, %{result: cleared}} = Stub.update_figure(channel, request, metadata: metadata)
      assert cleared.measure == nil
    end

    test "a read returns stored unions", %{channel: channel, metadata: metadata} do
      figure = create!(channel, metadata, %V1.CreateFigureRequest{measure: measure(:flag, true)})

      assert {:ok, %{result: figures}} =
               Stub.list_figures(channel, %V1.ListFiguresRequest{}, metadata: metadata)

      assert Enum.find(figures, &(&1.id == figure.id)).measure == measure(:flag, true)
    end

    test "an invalid member value is INVALID_ARGUMENT naming the field", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.CreateFigureRequest{measure: measure(:count, -1)}

      assert {:error, %RPCError{status: status, details: [detail | _]}} =
               Stub.create_figure(channel, request, metadata: metadata)

      assert status == Status.invalid_argument()
      assert %BadRequest{field_violations: [violation]} = BadRequest.decode(detail.value)
      assert violation.field == "measure"
    end
  end

  defp choice_resource(members) do
    """
    grpc do
      proto_message "Choice"
      fields id: 1, choice: 2
    end

    attributes do
      uuid_primary_key :id, public?: true
      attribute :choice, :union, constraints: [types: #{inspect(members)}], public?: true
    end
    """
  end
end
