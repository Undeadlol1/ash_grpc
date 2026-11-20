defmodule AshGrpc.GenericResultsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.TalliesEndpoint
  alias AshGrpc.TestSupport.TalliesEndpoint.Tallies.V1
  alias AshGrpc.TestSupport.TalliesEndpoint.Tallies.V1.Tallies.Stub
  alias Spark.Error.DslError

  describe "proto" do
    setup do
      [{_path, text}] = AshGrpc.Proto.render(TalliesEndpoint)
      %{text: text}
    end

    test "a scalar result is a result field", %{text: text} do
      assert text =~ "message ShoutResponse {\n  string result = 1;\n}"
    end

    test "a nullable result is optional", %{text: text} do
      assert text =~ "message MaybeWordResponse {\n  optional string result = 1;\n}"
    end

    test "an array result is repeated", %{text: text} do
      assert text =~ "message WordsResponse {\n  repeated string result = 1;\n}"
      assert text =~ "message EveryTallyResponse {\n  repeated Tally result = 1;\n}"
    end

    test "a map with fields is a message named after the rpc", %{text: text} do
      assert text =~ "message DigestResponse {\n  DigestResult result = 1;\n}"
      assert text =~ "message DigestResult {\n  int64 total = 1;\n  optional string note = 2;\n}"
    end

    test "an action without a return type has an empty response", %{text: text} do
      assert text =~ "message PingResponse {}"
    end
  end

  describe "compile errors" do
    test "an unmappable return type is rejected naming the action" do
      body = """
      grpc do
        proto_message "Thing"
        fields id: 1
      end

      attributes do
        uuid_primary_key :id, public?: true
      end

      actions do
        action :anything, :term do
          run fn _input, _context -> {:ok, 1} end
        end
      end
      """

      domain =
        compile_domain(
          ~s|package "things.v1"\nservice "Things" do\n  rpc INLINE, :anything, :anything\nend|,
          body
        )

      assert_raise DslError,
                   ~r/generic action :anything returns Ash.Type.Term, which has no protobuf mapping/,
                   fn ->
                     compile_endpoint(domain)
                   end
    end
  end

  describe "over a real connection" do
    setup do
      %{channel: start(TalliesEndpoint), metadata: signed_in("someone")}
    end

    test "scalar, array and map results round trip", %{channel: channel, metadata: metadata} do
      assert {:ok, %{result: "HEY"}} =
               Stub.shout(channel, %V1.ShoutRequest{word: "hey"}, metadata: metadata)

      assert {:ok, %{result: ["a", "b"]}} =
               Stub.words(channel, %V1.WordsRequest{}, metadata: metadata)

      assert {:ok, %{result: %V1.DigestResult{total: 3, note: nil}}} =
               Stub.digest(channel, %V1.DigestRequest{}, metadata: metadata)
    end

    test "a nil result is unset, not NOT_FOUND", %{channel: channel, metadata: metadata} do
      assert {:ok, %{result: nil}} =
               Stub.maybe_word(channel, %V1.MaybeWordRequest{}, metadata: metadata)
    end

    test "an action without a return type answers an empty response", %{
      channel: channel,
      metadata: metadata
    } do
      assert {:ok, %V1.PingResponse{}} = Stub.ping(channel, %V1.PingRequest{}, metadata: metadata)
    end

    test "an array of the resource is a list of its messages", %{
      channel: channel,
      metadata: metadata
    } do
      {:ok, _} =
        Stub.create_tally(channel, %V1.CreateTallyRequest{name: "listed"}, metadata: metadata)

      assert {:ok, %{result: tallies}} =
               Stub.every_tally(channel, %V1.EveryTallyRequest{}, metadata: metadata)

      listed = Enum.find(tallies, &(&1.name == "listed"))
      assert {listed.entry_count, listed.has_entries} == {0, false}
    end
  end
end
