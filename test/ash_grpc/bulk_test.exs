defmodule AshGrpc.BulkTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Badge
  alias AshGrpc.TestSupport.BulkEndpoint
  alias AshGrpc.TestSupport.BulkEndpoint.Bulk.V1, as: Bulk
  alias AshGrpc.TestSupport.BulkEndpoint.Bulk.V1.Memos.Stub
  alias AshGrpc.TestSupport.Memo
  alias AshGrpc.TestSupport.Seat
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status
  alias Spark.Error.DslError

  @resource """
  grpc do
    proto_message "Note"
    fields id: 1, title: 2
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read, create: [:title]]

    update :edit do
      accept [:title]
    end

    destroy :remove

    action :ping do
      run fn _input, _context -> :ok end
    end
  end
  """

  setup_all do
    :mnesia.start()
    {:atomic, :ok} = :mnesia.create_table(:ash_grpc_test_badges, attributes: [:_pkey, :val])
    :ok
  end

  setup do
    {:atomic, :ok} = :mnesia.clear_table(:ash_grpc_test_badges)

    %{
      channel: start(BulkEndpoint),
      owner: "owner#{System.unique_integer([:positive])}"
    }
  end

  defp memo(owner, title \\ "memo"), do: Ash.Seed.seed!(Memo, %{title: title, owner: owner})

  defp memos(owner), do: Memo |> Ash.read!(actor: %{name: owner}) |> Enum.sort_by(& &1.title)

  defp titles(owner), do: Enum.map(memos(owner), & &1.title)

  defp violations(%RPCError{details: [detail | _]}),
    do: BadRequest.decode(detail.value).field_violations

  defp inputs(titles), do: Enum.map(titles, &%Bulk.CreateMemosInput{title: &1})

  defp with_actions(extra),
    do: String.replace(@resource, "  action :ping do", extra <> "\n  action :ping do")

  defp proto_for(grpc_body, resource_body \\ @resource) do
    domain =
      compile_domain(~s(package "notes.v1"\nservice "Notes" do\n#{grpc_body}\nend), resource_body)

    assert [{_path, text}] = AshGrpc.Proto.render([domain])
    text
  end

  defp assert_invalid(grpc_body, message, resource_body \\ @resource) do
    domain =
      compile_domain(~s(package "notes.v1"\nservice "Notes" do\n#{grpc_body}\nend), resource_body)

    assert_raise DslError, message, fn -> AshGrpc.Schema.build([domain]) end
  end

  describe "bulk create" do
    test "creates every item and answers the records in request order", ctx do
      request = %Bulk.CreateMemosRequest{inputs: inputs(["first", "second", "third"])}

      assert {:ok, %Bulk.CreateMemosResponse{result: result}} =
               Stub.create_memos(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert Enum.map(result, & &1.title) == ["first", "second", "third"]
      assert Enum.all?(result, &(&1.owner == ctx.owner))
      assert titles(ctx.owner) == ["first", "second", "third"]
    end

    test "an empty list answers an empty result and creates nothing", ctx do
      assert {:ok, %Bulk.CreateMemosResponse{result: []}} =
               Stub.create_memos(ctx.channel, %Bulk.CreateMemosRequest{},
                 metadata: signed_in(ctx.owner)
               )

      assert titles(ctx.owner) == []
    end

    test "one bad item fails the whole call and saves nothing", ctx do
      request = %Bulk.CreateMemosRequest{inputs: inputs(["fine", "ok-too", "no"])}

      assert {:error, %RPCError{status: status}} =
               Stub.create_memos(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert status == Status.invalid_argument()
      assert titles(ctx.owner) == []
    end

    test "the error names the item and the field", ctx do
      request = %Bulk.CreateMemosRequest{inputs: inputs(["fine", "ok-too", "no", "also fine"])}

      assert {:error, %RPCError{} = error} =
               Stub.create_memos(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert [%{field: "inputs[2].title"}] = violations(error)
    end

    test "a missing required field names the item", ctx do
      request = %Bulk.CreateMemosRequest{
        inputs: [%Bulk.CreateMemosInput{title: "fine"}, %Bulk.CreateMemosInput{}]
      }

      assert {:error, %RPCError{} = error} =
               Stub.create_memos(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert [%{field: "inputs[1].title"}] = violations(error)
    end

    test "a failure in the last batch rolls back the batches already written", ctx do
      names = for(n <- 1..100, do: "badge #{n}") ++ ["boom"]

      request = %Bulk.CreateBadgesRequest{
        inputs: Enum.map(names, &%Bulk.CreateBadgesInput{name: &1})
      }

      assert {:error, %RPCError{}} =
               Stub.create_badges(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert Ash.read!(Badge) == []
    end

    test "a policy refusal is PERMISSION_DENIED and saves nothing", ctx do
      request = %Bulk.CreateMemosRequest{inputs: inputs(["fine"])}

      assert {:error, %RPCError{status: status}} =
               Stub.create_memos(ctx.channel, request, metadata: signed_in("banned"))

      assert status == Status.permission_denied()
    end

    test "more items than max_bulk_size is INVALID_ARGUMENT before anything runs", ctx do
      request = %Bulk.CreateFewMemosRequest{
        inputs: Enum.map(["one", "two", "three"], &%Bulk.CreateFewMemosInput{title: &1})
      }

      assert {:error, %RPCError{status: status}} =
               Stub.create_few_memos(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert status == Status.invalid_argument()
      assert titles(ctx.owner) == []
    end

    test "the default max_bulk_size is 100", ctx do
      over = %Bulk.CreateMemosRequest{inputs: inputs(for n <- 1..101, do: "memo #{n}")}
      at = %Bulk.CreateMemosRequest{inputs: inputs(for n <- 1..100, do: "memo #{n}")}

      assert {:error, %RPCError{status: refused}} =
               Stub.create_memos(ctx.channel, over, metadata: signed_in(ctx.owner))

      assert refused == Status.invalid_argument()

      assert {:ok, %{result: created}} =
               Stub.create_memos(ctx.channel, at, metadata: signed_in(ctx.owner))

      assert length(created) == 100
    end
  end

  describe "bulk update" do
    test "updates every listed record with the shared input", ctx do
      [first, second, untouched] = Enum.map(["one", "two", "three"], &memo(ctx.owner, &1))
      request = %Bulk.ArchiveMemosRequest{ids: [first.id, second.id]}

      assert {:ok, %Bulk.ArchiveMemosResponse{result: result}} =
               Stub.archive_memos(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert result |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([first.id, second.id])
      assert Enum.all?(result, & &1.archived)
      assert Ash.get!(Memo, untouched.id, actor: %{name: ctx.owner}).archived == false
    end

    test "passes the action's inputs once to every record", ctx do
      [first, second] = [memo(ctx.owner), memo(ctx.owner)]
      request = %Bulk.RetitleMemosRequest{ids: [first.id, second.id], title: "renamed"}

      assert {:ok, %{result: result}} =
               Stub.retitle_memos(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert Enum.map(result, & &1.title) == ["renamed", "renamed"]
    end

    test "a record the caller may not see is absent from the result", ctx do
      mine = memo(ctx.owner)
      theirs = memo("someone-else")
      request = %Bulk.ArchiveMemosRequest{ids: [mine.id, theirs.id, Ecto.UUID.generate()]}

      assert {:ok, %{result: [%{id: id}]}} =
               Stub.archive_memos(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert id == mine.id
      assert Ash.get!(Memo, theirs.id, actor: %{name: "someone-else"}).archived == false
    end

    test "an empty list answers an empty result", ctx do
      assert {:ok, %{result: []}} =
               Stub.archive_memos(ctx.channel, %Bulk.ArchiveMemosRequest{},
                 metadata: signed_in(ctx.owner)
               )
    end

    test "one failing record fails the whole call and updates nothing", ctx do
      [first, second] = [memo(ctx.owner, "keep"), memo(ctx.owner, "keep too")]
      request = %Bulk.RetitleMemosRequest{ids: [first.id, second.id], title: "no"}

      assert {:error, %RPCError{status: status}} =
               Stub.retitle_memos(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert status == Status.invalid_argument()
      assert titles(ctx.owner) == ["keep", "keep too"]
    end

    test "more ids than max_bulk_size is INVALID_ARGUMENT", ctx do
      ids = for _ <- 1..101, do: Ecto.UUID.generate()

      assert {:error, %RPCError{status: status}} =
               Stub.archive_memos(ctx.channel, %Bulk.ArchiveMemosRequest{ids: ids},
                 metadata: signed_in(ctx.owner)
               )

      assert status == Status.invalid_argument()
    end

    test "a malformed id is INVALID_ARGUMENT", ctx do
      assert {:error, %RPCError{status: status}} =
               Stub.archive_memos(ctx.channel, %Bulk.ArchiveMemosRequest{ids: ["not-a-uuid"]},
                 metadata: signed_in(ctx.owner)
               )

      assert status == Status.invalid_argument()
    end

    test "a composite primary key lists a key message per record", ctx do
      Ash.Seed.seed!(Seat, %{row: "A", number: 1})
      Ash.Seed.seed!(Seat, %{row: "A", number: 2})
      Ash.Seed.seed!(Seat, %{row: "B", number: 1})

      request = %Bulk.ReserveSeatsRequest{
        ids: [
          %Bulk.ReserveSeatsKey{row: "A", number: 1},
          %Bulk.ReserveSeatsKey{row: "B", number: 1}
        ],
        holder: "ada"
      }

      assert {:ok, %{result: result}} =
               Stub.reserve_seats(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert result |> Enum.map(&{&1.row, &1.number, &1.holder}) |> Enum.sort() == [
               {"A", 1, "ada"},
               {"B", 1, "ada"}
             ]

      assert [%{holder: nil}] =
               Seat |> Ash.read!() |> Enum.filter(&(&1.row == "A" and &1.number == 2))
    end
  end

  describe "bulk destroy" do
    test "destroys the listed records and answers them", ctx do
      [first, second, kept] = Enum.map(["one", "two", "three"], &memo(ctx.owner, &1))
      request = %Bulk.DeleteMemosRequest{ids: [first.id, second.id]}

      assert {:ok, %{result: result}} =
               Stub.delete_memos(ctx.channel, request,
                 metadata: signed_in(ctx.owner, %{"x-role" => "admin"})
               )

      assert result |> Enum.map(& &1.title) |> Enum.sort() == ["one", "two"]
      assert Enum.map(memos(ctx.owner), & &1.id) == [kept.id]
    end

    test "a policy refusal is PERMISSION_DENIED and destroys nothing", ctx do
      record = memo(ctx.owner)

      assert {:error, %RPCError{status: status}} =
               Stub.delete_memos(ctx.channel, %Bulk.DeleteMemosRequest{ids: [record.id]},
                 metadata: signed_in(ctx.owner)
               )

      assert status == Status.permission_denied()
      assert titles(ctx.owner) == ["memo"]
    end

    test "a composite primary key destroys by key message", ctx do
      Ash.Seed.seed!(Seat, %{row: "Z", number: 1})
      Ash.Seed.seed!(Seat, %{row: "Z", number: 2})
      request = %Bulk.DeleteSeatsRequest{ids: [%Bulk.DeleteSeatsKey{row: "Z", number: 2}]}

      assert {:ok, %{result: [%{row: "Z", number: 2}]}} =
               Stub.delete_seats(ctx.channel, request, metadata: signed_in(ctx.owner))

      assert [{"Z", 1}] =
               Seat
               |> Ash.read!()
               |> Enum.filter(&(&1.row == "Z"))
               |> Enum.map(&{&1.row, &1.number})
    end
  end

  describe "the proto" do
    setup do
      %{text: :protos |> BulkEndpoint.__ash_grpc__() |> hd() |> elem(1)}
    end

    test "bulk create takes a repeated item message and answers a repeated result", %{text: text} do
      assert text =~ "message CreateMemosInput {\n  optional string title = 1;\n}"
      assert text =~ "message CreateMemosRequest {\n  repeated CreateMemosInput inputs = 1;\n}"
      assert text =~ "message CreateMemosResponse {\n  repeated Memo result = 1;\n}"
    end

    test "bulk update takes repeated ids and the shared inputs once", %{text: text} do
      assert text =~ "message ArchiveMemosRequest {\n  repeated string ids = 1;\n}"

      assert text =~
               "message RetitleMemosRequest {\n  repeated string ids = 1;\n  optional string title = 2;\n}"

      assert text =~ "message ArchiveMemosResponse {\n  repeated Memo result = 1;\n}"
    end

    test "a composite primary key becomes a repeated key message", %{text: text} do
      assert text =~ "message ReserveSeatsKey {\n  string row = 1;\n  int64 number = 2;\n}"

      assert text =~
               "message ReserveSeatsRequest {\n  repeated ReserveSeatsKey ids = 1;\n  optional string holder = 3;\n}"
    end

    test "a rpc without bulk? renders as before" do
      text =
        proto_for("""
        rpc INLINE, :add, :create, args: [title: 1]
        rpc INLINE, :edit, :edit, args: [id: 1, title: 2], clear_fields: false
        """)

      assert text =~ "message AddRequest {\n  optional string title = 1;\n}"
      assert text =~ "message AddResponse {\n  Note result = 1;\n}"

      assert text =~
               "message EditRequest {\n  optional string id = 1;\n  optional string title = 2;\n}"
    end
  end

  describe "the verifier" do
    test "bulk? on a read is refused" do
      assert_invalid(
        "rpc INLINE, :list_notes, :read, bulk?: true, sort: false, filter: false, page: false",
        ~r/rpc :list_notes: `bulk\?` needs a create, update or destroy action; :read has type :read/
      )
    end

    test "bulk? on a generic action is refused" do
      assert_invalid(
        "rpc INLINE, :ping, :ping, bulk?: true",
        ~r/rpc :ping: `bulk\?` needs a create, update or destroy action; :ping has type :action/
      )
    end

    test "bulk? with clear_fields is refused" do
      assert_invalid(
        "rpc INLINE, :edit_all, :edit, bulk?: true, args: [id: 1, title: 2], clear_fields: true",
        ~r/rpc :edit_all: `bulk\?` cannot be combined with `clear_fields`/
      )
    end

    test "bulk? with a paging option is refused" do
      assert_invalid(
        "rpc INLINE, :add_all, :create, bulk?: true, args: [title: 1], page: true",
        ~r/rpc :add_all: `bulk\?` cannot be combined with `page`/
      )
    end

    test "max_bulk_size without bulk? is refused" do
      assert_invalid(
        "rpc INLINE, :add, :create, args: [title: 1], max_bulk_size: 5",
        ~r/rpc :add: `max_bulk_size` only applies with `bulk\?: true`/
      )
    end

    test "a bulk update whose action has an argument named like the primary key is refused" do
      assert_invalid(
        "rpc INLINE, :edit_all, :edit_by_id, bulk?: true, args: [id: 1, title: 2]",
        ~r/rpc :edit_all: `bulk\?` cannot take the primary key \[:id\] as an action argument/,
        with_actions("""
        update :edit_by_id do
          accept [:title]
          argument :id, :uuid
        end
        """)
      )
    end

    test "an input named ids on a bulk update is refused" do
      assert_invalid(
        "rpc INLINE, :tag_all, :tag, bulk?: true, args: [id: 1, ids: 2]",
        ~r/rpc :tag_all: `bulk\?` uses the request field :ids for the primary key/,
        with_actions("""
        update :tag do
          argument :ids, :string
        end
        """)
      )
    end
  end
end
