defmodule AshGrpc.AggregateFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.TalliesEndpoint
  alias AshGrpc.TestSupport.TalliesEndpoint.Tallies.V1
  alias AshGrpc.TestSupport.TalliesEndpoint.Tallies.V1.Tallies.Stub
  alias Spark.Error.DslError

  describe "proto" do
    test "aggregates are fields typed by the aggregate, nullable only when it can be nil" do
      [{_path, text}] = AshGrpc.Proto.render(TalliesEndpoint)

      assert text =~
               "message Tally {\n  string id = 1;\n  optional string name = 2;\n  int64 entry_count = 3;\n" <>
                 "  optional int64 entry_total = 4;\n  bool has_entries = 5;\n  repeated string labels = 6;\n}"
    end
  end

  describe "compile errors" do
    test "a private aggregate is rejected" do
      assert_raise DslError, ~r/Field :hidden_count is not public/, fn ->
        compile_resource(tally_resource("fields id: 1, hidden_count: 2"))
      end
    end

    test "a sensitive aggregate is rejected" do
      assert_raise DslError, ~r/Field :secret_count is sensitive/, fn ->
        compile_resource(tally_resource("fields id: 1, secret_count: 2"))
      end
    end
  end

  describe "over a real connection" do
    setup do
      %{channel: start(TalliesEndpoint), metadata: signed_in("someone")}
    end

    defp tally!(channel, metadata, name) do
      {:ok, %{result: tally}} =
        Stub.create_tally(channel, %V1.CreateTallyRequest{name: name}, metadata: metadata)

      tally
    end

    defp entry!(channel, metadata, tally, amount, label) do
      request = %V1.CreateEntryRequest{tally_id: tally.id, amount: amount, label: label}
      {:ok, _reply} = Stub.create_entry(channel, request, metadata: metadata)
    end

    defp tallies(channel, metadata) do
      {:ok, %{result: tallies}} =
        Stub.list_tallies(channel, %V1.ListTalliesRequest{}, metadata: metadata)

      Map.new(tallies, &{&1.name, &1})
    end

    test "count, sum, exists and list are loaded with the read", %{
      channel: channel,
      metadata: metadata
    } do
      full = tally!(channel, metadata, "full")
      entry!(channel, metadata, full, 3, "a")
      entry!(channel, metadata, full, 4, "b")
      tally!(channel, metadata, "empty")

      %{"full" => full, "empty" => empty} = tallies(channel, metadata)

      assert {full.entry_count, full.entry_total, full.has_entries} == {2, 7, true}
      assert Enum.sort(full.labels) == ["a", "b"]
      assert {empty.entry_count, empty.entry_total, empty.has_entries} == {0, nil, false}
      assert empty.labels == []
    end

    test "a create response carries the aggregates", %{channel: channel, metadata: metadata} do
      created = tally!(channel, metadata, "fresh")

      assert {created.entry_count, created.entry_total, created.has_entries} == {0, nil, false}
    end
  end

  defp tally_resource(fields) do
    """
    grpc do
      proto_message "Tally"
      #{fields}
    end

    attributes do
      uuid_primary_key :id, public?: true
    end

    relationships do
      has_many :entries, AshGrpc.TestSupport.Entry, public?: true, destination_attribute: :tally_id
    end

    aggregates do
      count :hidden_count, :entries
      count :secret_count, :entries, public?: true, sensitive?: true
    end
    """
  end
end
