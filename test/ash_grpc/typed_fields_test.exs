defmodule AshGrpc.TypedFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.Proto.Compatibility
  alias AshGrpc.TestSupport.Gadget
  alias AshGrpc.TestSupport.GadgetsEndpoint
  alias AshGrpc.TestSupport.GadgetsEndpoint.Gadgets.V1
  alias AshGrpc.TestSupport.GadgetsEndpoint.Gadgets.V1.Gadgets.Stub
  alias AshGrpc.Types
  alias Google.Protobuf.ListValue
  alias Google.Protobuf.Struct
  alias Google.Protobuf.Value
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status

  describe "kinds" do
    test "an atom without allowed values is an atom on the wire" do
      assert Types.kind(:atom) == {:ok, :atom}
    end

    test "maps are structs on the wire" do
      assert Types.kind(:map) == {:ok, :struct}
      assert Types.kind(Ash.Type.Map) == {:ok, :struct}
    end

    test "structs and keywords without fields constraints stay unmapped" do
      assert {:error, _reason} = Types.kind(:struct)
      assert {:error, _reason} = Types.kind(:keyword)
    end

    test "a struct kind is a message of google.protobuf.Struct" do
      assert Types.proto_type(:struct) == "google.protobuf.Struct"
      assert Types.field_type(:struct) == Struct
      assert Types.message?(:struct)
    end
  end

  describe "struct values" do
    test "nil encodes as nil" do
      assert Types.encode(:struct, nil) == nil
    end

    test "a map encodes with JSON-safe values" do
      encoded =
        Types.encode(:struct, %{
          name: "lamp",
          level: 3,
          ratio: 0.5,
          on: true,
          off: nil,
          mode: :eco,
          price: Decimal.new("9.99"),
          day: ~D[2026-11-11],
          tags: ["a", %{deep: 1}]
        })

      assert %Struct{fields: fields} = encoded
      assert fields["name"] == %Value{kind: {:string_value, "lamp"}}
      assert fields["level"] == %Value{kind: {:number_value, 3.0}}
      assert fields["ratio"] == %Value{kind: {:number_value, 0.5}}
      assert fields["on"] == %Value{kind: {:bool_value, true}}
      assert fields["off"] == %Value{kind: {:null_value, :NULL_VALUE}}
      assert fields["mode"] == %Value{kind: {:string_value, "eco"}}
      assert fields["price"] == %Value{kind: {:string_value, "9.99"}}
      assert fields["day"] == %Value{kind: {:string_value, "2026-11-11"}}

      assert %Value{kind: {:list_value, %ListValue{values: [first, second]}}} = fields["tags"]
      assert first == %Value{kind: {:string_value, "a"}}
      assert %Value{kind: {:struct_value, %Struct{fields: %{"deep" => _}}}} = second
    end

    test "a struct decodes to a map with string keys and whole numbers as integers" do
      source = %{
        "name" => "lamp",
        "level" => 3,
        "ratio" => 0.5,
        "off" => nil,
        "tags" => [1, %{"deep" => true}]
      }

      assert Types.decode(:struct, Types.encode(:struct, source)) == {:ok, source}
    end
  end

  describe "proto" do
    test "a message with a struct field imports struct.proto and the field is not optional" do
      [{_path, text}] = AshGrpc.Proto.render(GadgetsEndpoint)

      assert text =~ ~s(import "google/protobuf/struct.proto";)
      refute text =~ "timestamp.proto"
      assert text =~ "  google.protobuf.Struct settings = 5;"
      assert text =~ "  optional Mood mood = 3;"
      assert text =~ "  GadgetKind kind = 2;"
    end

    test "a field changing between string and Struct is breaking" do
      base =
        "syntax = \"proto3\";\npackage a.v1;\nmessage M {\n  optional string settings = 1;\n}\n"

      changed =
        String.replace(base, "optional string settings", "google.protobuf.Struct settings")

      assert [change] = Compatibility.check(base, changed)
      assert change =~ "field 1 changed"
    end
  end

  describe "over a real connection" do
    setup do
      %{channel: start(GadgetsEndpoint), actor: "someone"}
    end

    defp settings do
      %Struct{fields: %{"level" => %Value{kind: {:number_value, 7.0}}}}
    end

    test "attributes round trip through a create", %{channel: channel, actor: actor} do
      assert {:ok, %{result: gadget}} =
               Stub.create_gadget(
                 channel,
                 %V1.CreateGadgetRequest{
                   kind: :GADGET_KIND_FAN,
                   mood: :MOOD_WILD,
                   tier: :TIER_PRO,
                   settings: settings()
                 },
                 metadata: signed_in(actor)
               )

      assert gadget.kind == :GADGET_KIND_FAN
      assert gadget.mood == :MOOD_WILD
      assert gadget.tier == :TIER_PRO
      assert gadget.settings == settings()
    end

    test "arguments round trip through a create", %{channel: channel, actor: actor} do
      assert {:ok, %{result: gadget}} =
               Stub.build_gadget(
                 channel,
                 %V1.BuildGadgetRequest{
                   kind: :BUILD_GADGET_REQUEST_KIND_LAMP,
                   mood: :MOOD_CALM,
                   extra: settings()
                 },
                 metadata: signed_in(actor)
               )

      assert {gadget.kind, gadget.mood, gadget.tier} == {:GADGET_KIND_LAMP, :MOOD_CALM, nil}
      assert gadget.settings == settings()

      assert [%Gadget{settings: %{"level" => 7}}] =
               Gadget |> Ash.read!(authorize?: false) |> Enum.filter(&(&1.id == gadget.id))
    end

    test "unset optional fields stay unset", %{channel: channel, actor: actor} do
      assert {:ok, %{result: gadget}} =
               Stub.create_gadget(channel, %V1.CreateGadgetRequest{kind: :GADGET_KIND_LAMP},
                 metadata: signed_in(actor)
               )

      assert {gadget.mood, gadget.tier, gadget.settings} == {nil, nil, nil}
    end

    for {field, bad} <- [kind: 99, mood: 99, tier: 99] do
      test "an invalid #{field} is INVALID_ARGUMENT naming the field", %{
        channel: channel,
        actor: actor
      } do
        request =
          struct(V1.CreateGadgetRequest, [
            {:kind, :GADGET_KIND_LAMP},
            {unquote(field), unquote(bad)}
          ])

        assert {:error, %RPCError{status: status, details: [detail | _]}} =
                 Stub.create_gadget(channel, request, metadata: signed_in(actor))

        assert status == Status.invalid_argument()

        assert %BadRequest{field_violations: [%{field: field_name}]} =
                 BadRequest.decode(detail.value)

        assert field_name == unquote(Atom.to_string(field))
      end
    end

    test "an invalid enum argument is INVALID_ARGUMENT naming the argument", %{
      channel: channel,
      actor: actor
    } do
      assert {:error, %RPCError{status: status, details: [detail | _]}} =
               Stub.build_gadget(
                 channel,
                 %V1.BuildGadgetRequest{kind: :BUILD_GADGET_REQUEST_KIND_LAMP, mood: 99},
                 metadata: signed_in(actor)
               )

      assert status == Status.invalid_argument()
      assert %BadRequest{field_violations: [%{field: "mood"}]} = BadRequest.decode(detail.value)
    end
  end
end
