defmodule AshGrpc.EnumFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.Proto.Compatibility
  alias AshGrpc.TestSupport.Finish
  alias AshGrpc.TestSupport.GadgetsEndpoint
  alias AshGrpc.TestSupport.GadgetsEndpoint.Gadgets.V1
  alias AshGrpc.TestSupport.GadgetsEndpoint.Gadgets.V1.Gadgets.Stub
  alias AshGrpc.TestSupport.Mood
  alias AshGrpc.TestSupport.Tier
  alias AshGrpc.Types
  alias Google.Protobuf.Struct
  alias Google.Protobuf.Value
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status
  alias Spark.Error.DslError

  describe "kinds" do
    test "an Ash.Type.Enum is an enum named after its module, with its descriptions" do
      assert {:ok, {:enum, enum}} = Types.kind(Finish)

      assert enum == %{
               name: "Finish",
               values: [
                 %{value: :matte, description: "No shine"},
                 %{value: :gloss, description: "A high shine"}
               ]
             }
    end

    test "an atom with one_of is an enum that has no name yet" do
      assert {:ok, {:enum, %{name: nil, values: [%{value: :lamp}, %{value: :fan}]}}} =
               Types.kind(:atom, one_of: [:lamp, :fan])
    end

    test "a new type over one_of is named after the new type" do
      assert {:ok, {:enum, %{name: "Tier", values: [%{value: :basic}, %{value: :pro}]}}} =
               Types.kind(Tier)
    end

    test "an array of an enum is an array of its kind" do
      assert {:ok, {:array, {:enum, %{name: "Mood"}}}} = Types.kind({:array, Mood})
    end

    test "values are numbered from 1 after an unspecified 0, prefixed by the enum name" do
      {:ok, {:enum, %{values: values}}} = Types.kind(:atom, one_of: [:in_progress, :done])

      assert [{"PROGRESS_STATE_UNSPECIFIED", 0}, {"PROGRESS_STATE_IN_PROGRESS", 1}, done] =
               for(v <- Types.enum_values("ProgressState", values), do: {v.name, v.number})

      assert done == {"PROGRESS_STATE_DONE", 2}
    end

    test "a value that is not a protobuf name is rejected" do
      assert {:error, reason} = Types.kind(:atom, one_of: [:ok, :"not-ok"])
      assert reason =~ ~r/enum value :"not-ok".*not a protobuf name/
    end

    test "two values with one protobuf name are rejected" do
      assert {:error, reason} = Types.kind(:atom, one_of: [:a_b, :aB])
      assert reason =~ ~r/enum values that are all named A_B/
    end
  end

  describe "proto" do
    setup do
      [{_path, text}] = AshGrpc.Proto.render(GadgetsEndpoint)
      %{text: text}
    end

    test "enums come before messages, with value descriptions as comments", %{text: text} do
      assert text =~
               "enum Finish {\n  FINISH_UNSPECIFIED = 0;\n  // No shine\n  FINISH_MATTE = 1;\n  // A high shine\n  FINISH_GLOSS = 2;\n}"

      assert text =~ "enum Tier {\n  TIER_UNSPECIFIED = 0;\n  TIER_BASIC = 1;\n  TIER_PRO = 2;\n}"
      {enum_at, _length} = :binary.match(text, "enum Tier")
      {message_at, _length} = :binary.match(text, "message Gadget {")
      assert enum_at < message_at
    end

    test "an inline one_of enum is named after its parent and field", %{text: text} do
      assert text =~ "enum GadgetKind {\n  GADGET_KIND_UNSPECIFIED = 0;"
      assert text =~ "enum GadgetBoxShade {"
      assert text =~ "enum BuildGadgetRequestKind {"
    end

    test "enum fields keep presence: optional, repeated, in a nested message, in a union", %{
      text: text
    } do
      assert text =~ "  GadgetKind kind = 2;"
      assert text =~ "  optional Mood mood = 3;"
      assert text =~ "  repeated Mood moods = 6;"
      assert text =~ "  optional Finish finish = 9;"

      assert text =~
               "message GadgetBox {\n  GadgetBoxShade shade = 1;\n  optional Mood mood = 2;\n}"

      assert text =~
               "message GadgetPick {\n  oneof value {\n    Mood feel = 1;\n    int64 count = 2;"
    end

    test "generic action results and arguments are enums", %{text: text} do
      assert text =~ "message CurrentMoodResponse {\n  Mood result = 1;\n}"
      assert text =~ "message MoodsTodayResponse {\n  repeated Mood result = 1;\n}"
      assert text =~ "message EchoFinishRequest {\n  optional Finish finish = 1;\n}"
    end

    test "the rendered text is read back by the compatibility check", %{text: text} do
      assert Compatibility.check(text, text) == :ok
    end
  end

  describe "compatibility" do
    @base """
    syntax = "proto3";
    package a.v1;
    enum Mood {
      MOOD_UNSPECIFIED = 0;
      MOOD_CALM = 1;
      MOOD_WILD = 2;
    }
    message M {
      optional Mood mood = 1;
    }
    """

    test "a value added at the end is fine" do
      added = String.replace(@base, "  MOOD_WILD = 2;\n", "  MOOD_WILD = 2;\n  MOOD_ZEN = 3;\n")
      assert Compatibility.check(@base, added) == :ok
    end

    test "a removed value is breaking" do
      removed = String.replace(@base, "  MOOD_WILD = 2;\n", "")

      assert ["enum Mood: value 2 (`MOOD_WILD`) was removed." | _] =
               Compatibility.check(@base, removed)
    end

    test "a renumbered value is breaking" do
      renumbered =
        String.replace(
          @base,
          "MOOD_CALM = 1;\n  MOOD_WILD = 2;",
          "MOOD_WILD = 1;\n  MOOD_CALM = 2;"
        )

      assert [first, _second] = Compatibility.check(@base, renumbered)
      assert first =~ "enum Mood: value 1 changed from `MOOD_CALM` to `MOOD_WILD`"
    end

    test "a removed enum is breaking" do
      removed = String.replace(@base, ~r/enum Mood \{.*?\}\n/s, "")
      assert ["enum Mood was removed."] = Compatibility.check(@base, removed)
    end

    test "a field changing from string to an enum is breaking" do
      changed = String.replace(@base, "optional Mood mood", "optional string mood")
      assert [change] = Compatibility.check(@base, changed)
      assert change =~ "field 1 changed from `optional Mood mood` to `optional string mood`"
    end
  end

  describe "compile errors" do
    defp enum_module(path, values) do
      compile("""
      defmodule #{path} do
        use Ash.Type.Enum, values: #{inspect(values)}
      end
      """)

      path
    end

    defp holder(attributes) do
      names =
        attributes
        |> Enum.with_index(2)
        |> Enum.map_join(", ", fn {{name, _type}, number} -> "#{name}: #{number}" end)

      """
      grpc do
        proto_message "Holder"
        fields id: 1, #{names}
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

    defp build(attributes) do
      domain =
        compile_domain(
          ~s(package "holders.v1"\nservice "Holders" do\n rpc INLINE, :list_holders, :read, sort: false, filter: false, page: false\n end),
          holder(attributes)
        )

      AshGrpc.Schema.build([domain])
    end

    test "a value that is not a protobuf name is reported on the field" do
      module =
        enum_module("AshGrpc.Compiled.Bad#{System.unique_integer([:positive])}.Odd", ["a b"])

      assert_raise DslError, ~r/has the enum value "a b"/, fn ->
        compile_resource(holder(odd: module))
      end
    end

    test "two enums with one name and different values are rejected, naming both fields" do
      id = System.unique_integer([:positive])
      first = enum_module("AshGrpc.Compiled.First#{id}.Level", [:low, :high])
      second = enum_module("AshGrpc.Compiled.Second#{id}.Level", [:low, :max])

      assert_raise DslError,
                   ~r/Enum name "Level" is defined more than once.*Holder.first.*Holder.second/,
                   fn ->
                     build(first: first, second: second)
                   end
    end

    test "two fields of one enum are fine" do
      level =
        enum_module("AshGrpc.Compiled.Same#{System.unique_integer([:positive])}.Level", [:low])

      assert [%{enums: [%{name: "Level"}]}] = build(first: level, second: level)
    end

    test "an enum named like a message is rejected" do
      clash =
        enum_module(
          "AshGrpc.Compiled.Clash#{System.unique_integer([:positive])}.ListHoldersRequest",
          [:x]
        )

      assert_raise DslError, ~r/"ListHoldersRequest" is defined more than once/, fn ->
        build(clash: clash)
      end
    end

    test "a value name used by two enums is rejected, naming both" do
      id = System.unique_integer([:positive])
      mood = enum_module("AshGrpc.Compiled.A#{id}.Mood", [:calm_unspecified])
      calm = enum_module("AshGrpc.Compiled.B#{id}.MoodCalm", [:other])

      assert_raise DslError, ~r/"MOOD_CALM_UNSPECIFIED".*Mood, MoodCalm/, fn ->
        build(mood: mood, calm: calm)
      end
    end
  end

  describe "over a real connection" do
    setup do
      %{channel: start(GadgetsEndpoint), metadata: signed_in("someone")}
    end

    defp create!(channel, metadata, fields) do
      request = struct(V1.CreateGadgetRequest, [{:kind, :GADGET_KIND_LAMP} | fields])
      assert {:ok, %{result: gadget}} = Stub.create_gadget(channel, request, metadata: metadata)
      gadget
    end

    defp violation(result) do
      assert {:error, %RPCError{status: status, details: [detail | _]}} = result
      assert status == Status.invalid_argument()
      assert %BadRequest{field_violations: [violation]} = BadRequest.decode(detail.value)
      violation
    end

    test "enums in a repeated field, a nested message and a union round trip", %{
      channel: channel,
      metadata: metadata
    } do
      gadget =
        create!(channel, metadata,
          moods: [:MOOD_WILD, :MOOD_CALM],
          box: %V1.GadgetBox{shade: :GADGET_BOX_SHADE_DARK, mood: :MOOD_WILD},
          pick: %V1.GadgetPick{value: {:feel, :MOOD_CALM}},
          finish: :FINISH_GLOSS
        )

      assert gadget.moods == [:MOOD_WILD, :MOOD_CALM]
      assert gadget.box == %V1.GadgetBox{shade: :GADGET_BOX_SHADE_DARK, mood: :MOOD_WILD}
      assert gadget.pick == %V1.GadgetPick{value: {:feel, :MOOD_CALM}}
      assert gadget.finish == :FINISH_GLOSS

      stored = Ash.get!(AshGrpc.TestSupport.Gadget, gadget.id, authorize?: false)

      assert {stored.moods, stored.box, stored.finish} ==
               {[:wild, :calm], %{shade: :dark, mood: :wild}, :gloss}

      assert stored.pick.value == :calm
    end

    test "UNSPECIFIED is not sent, so the attribute stays empty", %{
      channel: channel,
      metadata: metadata
    } do
      gadget = create!(channel, metadata, mood: :MOOD_UNSPECIFIED, finish: :FINISH_UNSPECIFIED)

      assert {gadget.mood, gadget.finish} == {nil, nil}
    end

    test "an unknown number in a nested message is INVALID_ARGUMENT on the field", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.CreateGadgetRequest{
        kind: :GADGET_KIND_LAMP,
        box: %V1.GadgetBox{shade: 99}
      }

      violation = violation(Stub.create_gadget(channel, request, metadata: metadata))
      assert violation.field == "box"
      assert violation.description =~ "shade is not a known GadgetBoxShade"
    end

    test "an unknown number in a union member is INVALID_ARGUMENT on the field", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.CreateGadgetRequest{
        kind: :GADGET_KIND_LAMP,
        pick: %V1.GadgetPick{value: {:feel, 99}}
      }

      violation = violation(Stub.create_gadget(channel, request, metadata: metadata))
      assert violation.field == "pick"
      assert violation.description =~ "feel is not a known Mood"
    end

    test "an unknown number as a top level field says which enum it is not", %{
      channel: channel,
      metadata: metadata
    } do
      request = %V1.CreateGadgetRequest{kind: :GADGET_KIND_LAMP, tier: 99}
      violation = violation(Stub.create_gadget(channel, request, metadata: metadata))
      assert violation.field == "tier"
      assert violation.description =~ "is not a known Tier"
    end

    test "a generic action returns an enum, and an array of them", %{
      channel: channel,
      metadata: metadata
    } do
      assert {:ok, %{result: :MOOD_WILD}} =
               Stub.current_mood(channel, %V1.CurrentMoodRequest{}, metadata: metadata)

      assert {:ok, %{result: [:MOOD_CALM, :MOOD_WILD]}} =
               Stub.moods_today(channel, %V1.MoodsTodayRequest{}, metadata: metadata)
    end

    test "a generic action takes an enum argument", %{channel: channel, metadata: metadata} do
      assert {:ok, %{result: :FINISH_MATTE}} =
               Stub.echo_finish(channel, %V1.EchoFinishRequest{finish: :FINISH_MATTE},
                 metadata: metadata
               )
    end

    test "filters speak the Ash values, not the proto names", %{
      channel: channel,
      metadata: metadata
    } do
      wild = create!(channel, metadata, mood: :MOOD_WILD)
      calm = create!(channel, metadata, mood: :MOOD_CALM)

      filter = %Struct{
        fields: %{
          "mood" => %Value{
            kind:
              {:struct_value, %Struct{fields: %{"eq" => %Value{kind: {:string_value, "wild"}}}}}
          }
        }
      }

      assert {:ok, %{result: found}} =
               Stub.find_gadgets(channel, %V1.FindGadgetsRequest{filter: filter},
                 metadata: metadata
               )

      ids = Enum.map(found, & &1.id)
      assert wild.id in ids
      refute calm.id in ids
      assert Enum.all?(found, &(&1.mood == :MOOD_WILD))
    end
  end
end
