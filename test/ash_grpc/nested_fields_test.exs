defmodule AshGrpc.NestedFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Dimensions
  alias AshGrpc.TestSupport.Label
  alias AshGrpc.TestSupport.Parcel
  alias AshGrpc.TestSupport.ParcelsEndpoint
  alias AshGrpc.TestSupport.ParcelsEndpoint.Parcels.V1
  alias AshGrpc.TestSupport.ParcelsEndpoint.Parcels.V1.Parcels.Stub
  alias AshGrpc.Types
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status
  alias Spark.Error.DslError

  describe "kinds" do
    test "a typed struct is a message named after its module" do
      assert {:ok, {:fields, "Dimensions", [width, height]}} = Types.kind(Dimensions)
      assert {width.name, width.number, width.kind, width.optional?} == {:width, 1, :int64, false}
      assert {height.name, height.number, height.optional?} == {:height, 2, true}
    end

    test "an embedded resource, and a struct of one, is the resource's message" do
      assert Types.kind(Label) == {:ok, {:resource, Label}}
      assert Types.kind(:struct, instance_of: Label) == {:ok, {:resource, Label}}
    end

    test "a map or keyword with fields is an unnamed message numbered in declaration order" do
      fields = [b: [type: :string], a: [type: :integer]]

      for type <- [:map, :keyword] do
        assert {:ok, {:fields, nil, [b, a]}} = Types.kind(type, fields: fields)
        assert {b.name, b.number, a.name, a.number} == {:b, 1, :a, 2}
      end
    end
  end

  describe "proto" do
    setup do
      [{_path, text}] = AshGrpc.Proto.render(ParcelsEndpoint)
      %{text: text}
    end

    test "nested types are messages of their own, after the resource message", %{text: text} do
      assert text =~ "  Dimensions dimensions = 16;"
      assert text =~ "  repeated Label labels = 18;"
      assert text =~ "  repeated Dimensions extents = 19;"
      assert text =~ "  ParcelHandling handling = 20;"
      assert text =~ "  Label sticker = 22;"
      assert text =~ "message Dimensions {\n  int64 width = 1;\n  optional int64 height = 2;\n}"
      assert text =~ "message ParcelWeight {\n  int64 grams = 1;\n}"

      assert text =~
               "message ParcelHandling {\n  optional bool fragile = 1;\n  optional string note = 2;\n}"

      [before_parcel, _rest] = String.split(text, "message Parcel {")
      refute before_parcel =~ "message"
    end

    test "an embedded resource's message follows its grpc block", %{text: text} do
      assert text =~
               "message Label {\n  string text = 1;\n  optional string color = 2 [deprecated = true];\n  Dimensions size = 4;\n  reserved 3;\n}"
    end

    test "an accepted attribute's message is the resource's; an argument's is the request's", %{
      text: text
    } do
      assert text =~ "  ParcelWeight weight = 20;"
      assert text =~ "message PackParcelRequestBox {\n  optional int64 grams = 1;\n}"
      assert text =~ "  PackParcelRequestBox box = 5;"
    end

    test "identical messages are rendered once", %{text: text} do
      assert length(String.split(text, "message Dimensions {")) == 2
      assert length(String.split(text, "message Label {")) == 2
    end

    test "reordering the fields of a nested message is a breaking change", %{text: text} do
      reordered =
        String.replace(
          text,
          "  int64 width = 1;\n  optional int64 height = 2;",
          "  optional int64 height = 1;\n  int64 width = 2;"
        )

      assert [change | _] = AshGrpc.Proto.Compatibility.check(text, reordered)
      assert change =~ "message Dimensions: field 1 changed"
    end
  end

  describe "compile errors" do
    test "an embedded resource without a grpc block is rejected" do
      embedded = "AshGrpc.Compiled.Bare#{System.unique_integer([:positive])}"

      compile("""
      defmodule #{embedded} do
        use Ash.Resource, data_layer: :embedded

        attributes do
          attribute :text, :string, public?: true
        end
      end
      """)

      assert_raise DslError, ~r/does not use `AshGrpc.Resource`/, fn ->
        compile_resource(resource_with(embedded))
      end
    end

    test "an embedded resource sending a calculation is rejected" do
      embedded =
        embedded_resource(
          ~s(grpc do\n proto_message "Tag"\n fields text: 1, shout: 2\n end),
          "attribute :text, :string, public?: true",
          "calculations do\n calculate :shout, :string, expr(text <> \"!\"), public?: true\n end"
        )

      assert_raise DslError, ~r/include a calculation/, fn ->
        compile_resource(resource_with(embedded))
      end
    end

    test "two different messages with one name are rejected" do
      first = typed_struct("Size", "field :width, :integer")
      second = typed_struct("Size", "field :depth, :string")

      domain =
        compile_domain(
          ~s(package "sizes.v1"\nservice "Sizes" do\n rpc INLINE, :list_boxes, :read, sort: false, filter: false, page: false\n end),
          box_resource(first: first, second: second)
        )

      assert_raise DslError, ~r/"Size" is defined more than once/, fn ->
        AshGrpc.Schema.build([domain])
      end
    end

    test "a nested message named like an rpc message is rejected" do
      clashing = typed_struct("ListBoxesRequest", "field :width, :integer")

      domain =
        compile_domain(
          ~s(package "sizes.v1"\nservice "Sizes" do\n rpc INLINE, :list_boxes, :read, sort: false, filter: false, page: false\n end),
          box_resource(first: clashing)
        )

      assert_raise DslError, ~r/"ListBoxesRequest" is defined more than once/, fn ->
        AshGrpc.Schema.build([domain])
      end
    end
  end

  describe "over a real connection" do
    setup do
      %{channel: start(ParcelsEndpoint), metadata: signed_in("someone")}
    end

    defp create!(channel, metadata, request) do
      assert {:ok, %{result: parcel}} = Stub.create_parcel(channel, request, metadata: metadata)
      parcel
    end

    defp label, do: %V1.Label{text: "fragile", color: "red", size: %V1.Dimensions{width: 2}}

    test "nested values round trip through a create", %{channel: channel, metadata: metadata} do
      parcel =
        create!(channel, metadata, %V1.CreateParcelRequest{
          dimensions: %V1.Dimensions{width: 3, height: 4},
          label: label(),
          labels: [label(), %V1.Label{text: "plain"}],
          extents: [%V1.Dimensions{width: 1}, %V1.Dimensions{width: 5, height: 6}],
          handling: %V1.ParcelHandling{fragile: true, note: "this side up"},
          weight: %V1.ParcelWeight{grams: 500},
          sticker: %V1.Label{text: "sticker"}
        })

      assert parcel.dimensions == %V1.Dimensions{width: 3, height: 4}
      assert parcel.label == label()
      assert parcel.labels == [label(), %V1.Label{text: "plain"}]
      assert parcel.extents == [%V1.Dimensions{width: 1}, %V1.Dimensions{width: 5, height: 6}]
      assert parcel.handling == %V1.ParcelHandling{fragile: true, note: "this side up"}
      assert parcel.weight == %V1.ParcelWeight{grams: 500}
      assert parcel.sticker == %V1.Label{text: "sticker"}

      stored = Ash.get!(Parcel, parcel.id, authorize?: false)

      assert %Dimensions{width: 3, height: 4} = stored.dimensions
      assert %Label{text: "fragile", size: %Dimensions{width: 2}} = stored.label
      assert %{grams: 500} = stored.weight
      assert Keyword.get(stored.handling, :fragile) == true
    end

    test "unset nested values are unset", %{channel: channel, metadata: metadata} do
      parcel = create!(channel, metadata, %V1.CreateParcelRequest{})

      assert {parcel.dimensions, parcel.label, parcel.labels, parcel.extents} ==
               {nil, nil, [], []}
    end

    test "a nested argument reaches the action", %{channel: channel, metadata: metadata} do
      request = %V1.PackParcelRequest{box: %V1.PackParcelRequestBox{grams: 7}}

      assert {:ok, %{result: parcel}} = Stub.pack_parcel(channel, request, metadata: metadata)
      assert parcel.weight == %V1.ParcelWeight{grams: 7}
    end

    test "an update replaces a typed struct and updates an embedded resource", %{
      channel: channel,
      metadata: metadata
    } do
      parcel = create!(channel, metadata, %V1.CreateParcelRequest{label: label()})

      request = %V1.UpdateParcelRequest{
        id: parcel.id,
        label: %V1.Label{text: "changed"},
        dimensions: %V1.Dimensions{width: 9}
      }

      assert {:ok, %{result: updated}} = Stub.update_parcel(channel, request, metadata: metadata)
      assert updated.label == %{label() | text: "changed"}
      assert updated.dimensions == %V1.Dimensions{width: 9}
    end

    test "an invalid nested value is INVALID_ARGUMENT naming the field", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.CreateParcelRequest{label: %V1.Label{color: "red"}}

      assert {:error, %RPCError{status: status, details: [detail | _]}} =
               Stub.create_parcel(channel, request, metadata: metadata)

      assert status == Status.invalid_argument()
      assert %BadRequest{field_violations: [violation]} = BadRequest.decode(detail.value)
      assert violation.field == "label.text"
    end

    test "an invalid item of a nested array names the item", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.CreateParcelRequest{labels: [label(), %V1.Label{color: "red"}]}

      assert {:error, %RPCError{details: [detail | _]}} =
               Stub.create_parcel(channel, request, metadata: metadata)

      assert %BadRequest{field_violations: [violation]} = BadRequest.decode(detail.value)
      assert violation.field == "labels[1].text"
    end

    test "an optional nested field hidden by a field policy is sent unset", %{channel: channel} do
      parcel =
        create!(channel, signed_in("someone"), %V1.CreateParcelRequest{
          label: label(),
          seal: %V1.Label{text: "secret"}
        })

      assert {:ok, %{result: [listed]}} =
               channel
               |> Stub.list_parcels(%V1.ListParcelsRequest{},
                 metadata: signed_in("hush-seal")
               )
               |> then(fn {:ok, reply} ->
                 {:ok, %{reply | result: Enum.filter(reply.result, &(&1.id == parcel.id))}}
               end)

      assert {listed.seal, listed.label} == {nil, label()}
    end

    test "a subscription sends nested values", %{channel: channel, metadata: metadata} do
      parcel = create!(channel, metadata, %V1.CreateParcelRequest{labels: [label()]})

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

      assert watched.labels == [label()]
    end
  end

  defp embedded_resource(grpc, attributes, extra) do
    name = "AshGrpc.Compiled.Embedded#{System.unique_integer([:positive])}"

    compile("""
    defmodule #{name} do
      use Ash.Resource, data_layer: :embedded, extensions: [AshGrpc.Resource]
      #{grpc}
      attributes do
        #{attributes}
      end
      #{extra}
    end
    """)

    name
  end

  defp resource_with(embedded) do
    """
    grpc do
      proto_message "Holder"
      fields id: 1, held: 2
    end

    attributes do
      uuid_primary_key :id, public?: true
      attribute :held, #{embedded}, public?: true
    end
    """
  end

  defp typed_struct(name, fields) do
    module = "AshGrpc.Compiled.Struct#{System.unique_integer([:positive])}.#{name}"

    compile(
      "defmodule #{module} do\n use Ash.TypedStruct\n typed_struct do\n #{fields}\n end\n end"
    )

    module
  end

  defp box_resource(attributes) do
    """
    grpc do
      proto_message "Box"
      fields #{attributes |> Enum.with_index(2) |> Enum.map_join(", ", fn {{name, _}, n} -> "#{name}: #{n}" end)}, id: 1
    end

    actions do
      defaults [:read]
    end

    attributes do
      uuid_primary_key :id, public?: true
      #{Enum.map_join(attributes, "\n", fn {name, type} -> "attribute :#{name}, #{type}, public?: true" end)}
    end
    """
  end
end
