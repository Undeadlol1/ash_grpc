defmodule AshGrpc.ResourceGroupTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.Domain.Info
  alias AshGrpc.TestSupport.GroupedEndpoint
  alias AshGrpc.TestSupport.GroupedEndpoint.Grouped.V1
  alias AshGrpc.TestSupport.GroupedEndpoint.Grouped.V1.Dispatches.Stub
  alias Spark.Error.DslError

  @note """
  grpc do
    proto_message "Memo"
    fields id: 1, title: 2
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
  end

  actions do
    create :create_memo do
      accept [:title]
    end

    create :make_memo do
      accept [:title]
    end

    read :list_memos do
      primary? true
    end

    read :watch_memos
  end
  """

  @memo "AshGrpc.ResourceGroupTest.Memo"

  setup_all do
    compile(resource_source(@memo, @note))
    :ok
  end

  defp domain(body), do: compile_domain(~s(package "memos.v1"\nservice "Memos" do\n#{body}\nend))

  defp calls(body),
    do: body |> domain() |> Info.grpc() |> Enum.flat_map(&(&1.rpcs ++ &1.subscriptions))

  defp proto(body), do: AshGrpc.Proto.render([domain(body)], previous: %{})

  describe "a grouped rpc" do
    test "GIVEN a call named like an action WHEN grouped THEN it takes the resource and that action" do
      [rpc] = calls("resource #{@memo} do\nrpc :create_memo\nend")

      assert {rpc.name, rpc.resource, rpc.action} ==
               {:create_memo, Module.concat([@memo]), :create_memo}
    end

    test "GIVEN a call and an action WHEN grouped THEN both are kept" do
      [rpc] = calls("resource #{@memo} do\nrpc :add_memo, :create_memo\nend")

      assert {rpc.name, rpc.action} == {:add_memo, :create_memo}
    end

    test "GIVEN options WHEN grouped THEN they apply" do
      [rpc] =
        calls("resource #{@memo} do\nrpc :list_memos, :list_memos, page: false, sort: false\nend")

      assert {rpc.page, rpc.sort} == {false, false}
    end

    test "GIVEN a grouped subscription WHEN the domain compiles THEN it streams the resource" do
      [rpc] = calls("resource #{@memo} do\nsubscription :watch_memos\nend")

      assert {rpc.stream?, rpc.resource, rpc.action} ==
               {true, Module.concat([@memo]), :watch_memos}
    end

    test "GIVEN several calls in a group WHEN the domain compiles THEN they keep source order" do
      names =
        calls("resource #{@memo} do\nrpc :make_memo\nrpc :create_memo\nrpc :list_memos\nend")

      assert Enum.map(names, & &1.name) == [:make_memo, :create_memo, :list_memos]
    end

    test "GIVEN a group between one-liners WHEN the domain compiles THEN source order holds" do
      body = """
      rpc #{@memo}, :make_memo
      resource #{@memo} do
        rpc :create_memo
        rpc :add_memo, :make_memo
      end
      rpc #{@memo}, :list_memos
      """

      assert Enum.map(calls(body), & &1.name) == [
               :make_memo,
               :create_memo,
               :add_memo,
               :list_memos
             ]
    end

    test "GIVEN the same calls grouped and as one-liners WHEN rendered THEN the proto is identical" do
      grouped =
        "resource #{@memo} do\nrpc :create_memo\nrpc :add_memo, :make_memo\nrpc :list_memos\nend"

      lines =
        "rpc #{@memo}, :create_memo\nrpc #{@memo}, :add_memo, :make_memo\nrpc #{@memo}, :list_memos"

      assert proto(grouped) == proto(lines)
    end
  end

  describe "the group's edges" do
    test "GIVEN an empty group WHEN the domain compiles THEN it has no calls" do
      assert calls("resource #{@memo} do\nend") == []
    end

    test "GIVEN the resource written inside the group WHEN the domain compiles THEN the error says it is given" do
      error =
        assert_raise DslError, fn ->
          domain("resource #{@memo} do\nrpc #{@memo}, :create_memo\nend")
        end

      assert error.message =~
               "inside `resource` the resource is already given: `rpc :create_memo`"
    end

    test "GIVEN the resource written in a grouped subscription WHEN the domain compiles THEN it fails the same way" do
      assert_raise DslError, ~r/inside `resource` the resource is already given/, fn ->
        domain("resource #{@memo} do\nsubscription #{@memo}, :watch_memos\nend")
      end
    end

    test "GIVEN a name used in a group and as a one-liner WHEN built THEN the names-repeat error is raised" do
      body = "resource #{@memo} do\nrpc :create_memo\nend\nrpc #{@memo}, :create_memo"

      error = assert_raise DslError, fn -> AshGrpc.Schema.build([domain(body)], previous: %{}) end

      assert error.message =~ "Rpc names repeat"
    end

    test "GIVEN an unknown call in a group WHEN built THEN the error says to name the action" do
      body = "resource #{@memo} do\nrpc :nope\nend"

      error = assert_raise DslError, fn -> AshGrpc.Schema.build([domain(body)], previous: %{}) end

      assert error.message =~ "nope"
      assert error.message =~ "name the action as the third argument"
    end
  end

  describe "over the wire" do
    setup do
      %{channel: start(GroupedEndpoint), metadata: signed_in("someone")}
    end

    test "GIVEN a grouped create and read WHEN called THEN the record round-trips", ctx do
      title = "t#{System.unique_integer([:positive])}"

      assert {:ok, %V1.CreateDispatchResponse{result: %V1.Dispatch{id: id}}} =
               Stub.create_dispatch(ctx.channel, %V1.CreateDispatchRequest{title: title},
                 metadata: ctx.metadata
               )

      assert {:ok, %V1.ListDispatchesResponse{result: dispatches}} =
               Stub.list_dispatches(ctx.channel, %V1.ListDispatchesRequest{},
                 metadata: ctx.metadata
               )

      assert Enum.any?(dispatches, &(&1.id == id and &1.title == title))
    end
  end
end
