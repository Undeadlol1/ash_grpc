defmodule AshGrpc.DefaultActionTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.Domain.Info
  alias AshGrpc.TestSupport.DefaultsEndpoint
  alias AshGrpc.TestSupport.DefaultsEndpoint.Defaults.V1
  alias AshGrpc.TestSupport.DefaultsEndpoint.Defaults.V1.Logbooks.Stub
  alias Spark.Error.DslError

  @note """
  grpc do
    proto_message "Note"
    fields id: 1, title: 2
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
  end

  actions do
    create :create_note do
      accept [:title]
    end

    update :update_note do
      accept [:title]
    end

    destroy :destroy_note

    read :list_notes do
      primary? true
    end

    read :get_note do
      get? true
      argument :title, :string, allow_nil?: false
      filter expr(title == ^arg(:title))
    end

    read :watch_notes

    action :shout, :string do
      run fn _input, _context -> {:ok, "hi"} end
    end

    create :make_note do
      accept [:title]
    end

    create :list_things do
      accept [:title]
    end
  end
  """

  setup_all do
    compile(resource_source("AshGrpc.DefaultActionTest.Note", @note))
    :ok
  end

  defp domain(body), do: compile_domain(~s(package "notes.v1"\nservice "Notes" do\n#{body}\nend))

  defp rpc_of(body) do
    [rpc] = body |> domain() |> Info.grpc() |> Enum.flat_map(&(&1.rpcs ++ &1.subscriptions))
    rpc
  end

  defp proto(body), do: AshGrpc.Proto.render([domain(body)], previous: %{})

  describe "an omitted action" do
    test "GIVEN a create named like the call WHEN the action is omitted THEN the rpc runs it" do
      assert rpc_of("rpc AshGrpc.DefaultActionTest.Note, :create_note").action == :create_note
    end

    test "GIVEN an update named like the call WHEN the action is omitted THEN the rpc runs it" do
      assert rpc_of("rpc AshGrpc.DefaultActionTest.Note, :update_note").action == :update_note
    end

    test "GIVEN a destroy named like the call WHEN the action is omitted THEN the rpc runs it" do
      assert rpc_of("rpc AshGrpc.DefaultActionTest.Note, :destroy_note").action == :destroy_note
    end

    test "GIVEN a list read and a get read WHEN the action is omitted THEN each keeps its own shape" do
      note = "AshGrpc.DefaultActionTest.Note"

      schema =
        AshGrpc.Schema.build([domain("rpc #{note}, :list_notes\nrpc #{note}, :get_note")],
          previous: %{}
        )

      [%{services: [service]}] = schema
      result = fn name -> Enum.find(service.rpcs, &(&1.name == name)).response end

      refute result.(:list_notes) == result.(:get_note)
    end

    test "GIVEN a generic action named like the call WHEN the action is omitted THEN the rpc runs it" do
      assert rpc_of("rpc AshGrpc.DefaultActionTest.Note, :shout").action == :shout
    end

    test "GIVEN a subscription named like a read WHEN the action is omitted THEN it watches that read" do
      assert rpc_of("subscription AshGrpc.DefaultActionTest.Note, :watch_notes").action ==
               :watch_notes
    end

    test "GIVEN options WHEN the action is omitted THEN the options still apply" do
      rpc = rpc_of("rpc AshGrpc.DefaultActionTest.Note, :list_notes, sort: false, page: false")

      assert {rpc.action, rpc.sort, rpc.page} == {:list_notes, false, false}
    end

    test "GIVEN options WHEN the action is written THEN both forms read the same" do
      rpc = rpc_of("rpc AshGrpc.DefaultActionTest.Note, :make_note, :create_note, args: [:title]")

      assert {rpc.action, rpc.args} == {:create_note, [:title]}
    end

    test "GIVEN an omitted action WHEN the proto is rendered THEN it equals the written form" do
      note = "AshGrpc.DefaultActionTest.Note"

      assert proto("rpc #{note}, :create_note") ==
               proto("rpc #{note}, :create_note, :create_note")
    end
  end

  describe "the resource comes first" do
    test "GIVEN the old order WHEN the domain compiles THEN it says the resource comes first" do
      error =
        assert_raise DslError, fn ->
          domain("rpc :create_note, AshGrpc.DefaultActionTest.Note, :create_note")
        end

      assert error.message =~ "resource comes first: `rpc MyApp.Post, :name`"
    end

    test "GIVEN the old order without an action WHEN the domain compiles THEN it fails the same way" do
      assert_raise DslError, ~r/resource comes first/, fn ->
        domain("subscription :watch_notes, AshGrpc.DefaultActionTest.Note")
      end
    end

    test "GIVEN the resource, the call and the action WHEN the domain compiles THEN all three are kept" do
      rpc = rpc_of("rpc AshGrpc.DefaultActionTest.Note, :make_it, :create_note")

      assert {rpc.name, rpc.action, rpc.action_defaulted?} == {:make_it, :create_note, false}
    end
  end

  describe "a written action" do
    test "GIVEN an action named like the call and another one WHEN the other is written THEN it wins" do
      rpc = rpc_of("rpc AshGrpc.DefaultActionTest.Note, :list_things, :make_note")

      assert rpc.action == :make_note
    end
  end

  describe "no action with the call's name" do
    test "GIVEN an unknown call name WHEN built THEN the error names the call, the resource and the actions" do
      domain = domain("rpc AshGrpc.DefaultActionTest.Note, :nope")

      error = assert_raise DslError, fn -> AshGrpc.Schema.build([domain], previous: %{}) end

      assert error.message =~ "nope"
      assert error.message =~ "AshGrpc.DefaultActionTest.Note"
      assert error.message =~ ":create_note"
      assert error.message =~ "name the action as the third argument"
    end

    test "GIVEN a subscription without a matching read WHEN built THEN it fails the same way" do
      domain = domain("subscription AshGrpc.DefaultActionTest.Note, :watch_nothing")

      error = assert_raise DslError, fn -> AshGrpc.Schema.build([domain], previous: %{}) end

      assert error.message =~ "name the action as the third argument"
    end

    test "GIVEN a written action that does not exist THEN the hint is not added" do
      domain = domain("rpc AshGrpc.DefaultActionTest.Note, :nope, :missing")

      error = assert_raise DslError, fn -> AshGrpc.Schema.build([domain], previous: %{}) end

      refute error.message =~ "as the third argument"
    end
  end

  describe "over the wire" do
    setup do
      %{channel: start(DefaultsEndpoint), metadata: signed_in("someone")}
    end

    test "GIVEN omitted actions WHEN a create and a read are called THEN the record round-trips",
         ctx do
      title = "t#{System.unique_integer([:positive])}"

      assert {:ok, %V1.CreateLogbookResponse{result: %V1.Logbook{id: id}}} =
               Stub.create_logbook(ctx.channel, %V1.CreateLogbookRequest{title: title},
                 metadata: ctx.metadata
               )

      assert {:ok, %V1.ListLogbooksResponse{result: logbooks}} =
               Stub.list_logbooks(ctx.channel, %V1.ListLogbooksRequest{}, metadata: ctx.metadata)

      assert Enum.any?(logbooks, &(&1.id == id and &1.title == title))
    end
  end
end
