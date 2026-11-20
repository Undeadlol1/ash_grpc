defmodule AshGrpc.PageSortFilterTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.Proto.Compatibility
  alias AshGrpc.TestSupport.Book
  alias AshGrpc.TestSupport.ShelfEndpoint
  alias AshGrpc.TestSupport.ShelfEndpoint.Shelf.V1
  alias AshGrpc.TestSupport.ShelfEndpoint.Shelf.V1.Shelf.Stub
  alias AshGrpc.Types
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status
  alias Spark.Error.DslError

  defp proto_text do
    [{_path, text}] = AshGrpc.Proto.render(ShelfEndpoint)
    text
  end

  describe "proto" do
    test "an rpc without page, sort or filter is unchanged" do
      assert proto_text() =~ "message ListBooksRequest {}\n"
      assert proto_text() =~ "message ListBooksResponse {\n  repeated Book result = 1;\n}\n"
    end

    test "sort and filter are request fields with the numbers given" do
      assert proto_text() =~
               "message SearchBooksRequest {\n  optional string sort = 1;\n  google.protobuf.Struct filter = 2;\n}\n"

      assert proto_text() =~ ~s(import "google/protobuf/struct.proto";)
    end

    test "page fields are request fields and the response says how to go on" do
      assert proto_text() =~
               "message PageBooksRequest {\n  optional int64 limit = 1;\n  optional int64 offset = 2;\n" <>
                 "  optional string after = 3;\n  optional string before = 4;\n  optional bool count = 5;\n" <>
                 "  optional string sort = 6;\n  google.protobuf.Struct filter = 7;\n}\n"

      assert proto_text() =~
               "message PageBooksResponse {\n  repeated Book result = 1;\n  bool has_more = 3;\n" <>
                 "  optional int64 count = 4;\n  optional string first_keyset = 5;\n" <>
                 "  optional string last_keyset = 6;\n}\n"
    end

    test "the response carries only what the page fields allow" do
      assert proto_text() =~
               "message RequiredBooksResponse {\n  repeated Book result = 1;\n  bool has_more = 3;\n}\n"

      assert proto_text() =~
               "message ScrollBooksResponse {\n  repeated Book result = 1;\n  bool has_more = 3;\n" <>
                 "  optional string first_keyset = 5;\n  optional string last_keyset = 6;\n}\n"
    end

    test "response meta keeps its number next to the page fields" do
      [{_path, text}] = AshGrpc.Proto.render([AshGrpc.TestSupport.Shelf], response_meta: true)

      assert text =~
               "message RequiredBooksResponse {\n  repeated Book result = 1;\n" <>
                 "  optional string meta = 2;\n  bool has_more = 3;\n}\n"
    end

    test "the breaking-change check sees a removed sort, filter or page field" do
      for line <- [
            "  optional string sort = 6;\n",
            "  google.protobuf.Struct filter = 7;\n",
            "  optional string after = 3;\n",
            "  optional int64 count = 4;\n"
          ] do
        without = String.replace(proto_text(), line, "", global: false)

        assert [change] = Compatibility.check(proto_text(), without)
        assert change =~ "was removed but its number is not reserved"
        assert Compatibility.check(without, proto_text()) == :ok
      end
    end
  end

  describe "over a real connection" do
    setup do
      owner = "reader#{System.unique_integer([:positive])}"
      %{channel: start(ShelfEndpoint), owner: owner, metadata: signed_in(owner)}
    end

    defp shelve!(owner, title, attrs) do
      Book
      |> Ash.Changeset.for_create(:create, Map.merge(%{title: title, owner: owner}, attrs))
      |> Ash.create!(authorize?: false)
    end

    defp shelve_five!(owner) do
      for {title, pages, genre} <- [
            {"a", 100, "poetry"},
            {"b", 500, "novel"},
            {"c", 300, "poetry"},
            {"d", 200, "novel"},
            {"e", 400, "essay"}
          ],
          do: shelve!(owner, title, %{pages: pages, genre: genre})
    end

    defp titles(books), do: Enum.map(books, & &1.title)

    defp page!(channel, metadata, request) do
      assert {:ok, response} = Stub.page_books(channel, request, metadata: metadata)
      response
    end

    defp search!(channel, metadata, request) do
      assert {:ok, %{result: books}} = Stub.search_books(channel, request, metadata: metadata)
      titles(books)
    end

    defp assert_invalid(result, field) do
      assert {:error, %RPCError{status: status, details: [detail | _]}} = result
      assert status == Status.invalid_argument()
      assert %BadRequest{field_violations: [%{field: ^field}]} = BadRequest.decode(detail.value)
    end

    test "offset pages", %{channel: channel, owner: owner, metadata: metadata} do
      shelve_five!(owner)

      first = page!(channel, metadata, %V1.PageBooksRequest{limit: 2, sort: "title"})
      last = page!(channel, metadata, %V1.PageBooksRequest{limit: 2, offset: 4, sort: "title"})

      assert {titles(first.result), first.has_more} == {["a", "b"], true}
      assert {titles(last.result), last.has_more} == {["e"], false}
    end

    test "the action's default limit applies when no limit is sent", %{
      channel: channel,
      owner: owner,
      metadata: metadata
    } do
      shelve_five!(owner)

      response = page!(channel, metadata, %V1.PageBooksRequest{sort: "title"})

      assert {titles(response.result), response.has_more} == {["a", "b"], true}
    end

    test "a limit over the max page size is cut to it", %{
      channel: channel,
      owner: owner,
      metadata: metadata
    } do
      shelve_five!(owner)

      response = page!(channel, metadata, %V1.PageBooksRequest{limit: 50, sort: "title"})

      assert titles(response.result) == ["a", "b", "c"]
    end

    test "count is sent only when asked for", %{
      channel: channel,
      owner: owner,
      metadata: metadata
    } do
      shelve_five!(owner)

      counted = page!(channel, metadata, %V1.PageBooksRequest{limit: 2, count: true})
      uncounted = page!(channel, metadata, %V1.PageBooksRequest{limit: 2})

      assert {counted.count, uncounted.count} == {5, nil}
    end

    test "keyset pages forward and back", %{channel: channel, owner: owner, metadata: metadata} do
      shelve_five!(owner)

      first = page!(channel, metadata, %V1.PageBooksRequest{limit: 2, sort: "title"})

      second =
        page!(channel, metadata, %V1.PageBooksRequest{
          limit: 2,
          sort: "title",
          after: first.last_keyset
        })

      back =
        page!(channel, metadata, %V1.PageBooksRequest{
          limit: 2,
          sort: "title",
          before: second.first_keyset
        })

      assert titles(second.result) == ["c", "d"]
      assert second.has_more
      assert titles(back.result) == ["a", "b"]
      refute back.has_more
    end

    test "a malformed keyset is INVALID_ARGUMENT", %{channel: channel, metadata: metadata} do
      result =
        Stub.page_books(channel, %V1.PageBooksRequest{limit: 2, after: "not a keyset"},
          metadata: metadata
        )

      assert {:error, %RPCError{status: status}} = result
      assert status == Status.invalid_argument()
    end

    test "a read that requires pagination needs a limit", %{
      channel: channel,
      owner: owner,
      metadata: metadata
    } do
      shelve_five!(owner)

      assert {:error, %RPCError{status: status}} =
               Stub.required_books(channel, %V1.RequiredBooksRequest{}, metadata: metadata)

      assert {:ok, %{result: [_one], has_more: true}} =
               Stub.required_books(channel, %V1.RequiredBooksRequest{limit: 1},
                 metadata: metadata
               )

      assert status == Status.invalid_argument()
    end

    test "sort ascending, descending and by many fields", %{
      channel: channel,
      owner: owner,
      metadata: metadata
    } do
      shelve_five!(owner)

      assert search!(channel, metadata, %V1.SearchBooksRequest{sort: "pages"}) ==
               ["a", "d", "c", "e", "b"]

      assert search!(channel, metadata, %V1.SearchBooksRequest{sort: "-pages"}) ==
               ["b", "e", "c", "d", "a"]

      assert search!(channel, metadata, %V1.SearchBooksRequest{sort: "genre,-pages"}) ==
               ["e", "b", "d", "c", "a"]
    end

    test "an unknown or private sort field is INVALID_ARGUMENT naming sort", %{
      channel: channel,
      metadata: metadata
    } do
      for sort <- ["nope", "secret", "-"] do
        assert_invalid(
          Stub.search_books(channel, %V1.SearchBooksRequest{sort: sort}, metadata: metadata),
          "sort"
        )
      end
    end

    test "a simple filter", %{channel: channel, owner: owner, metadata: metadata} do
      shelve_five!(owner)

      request = %V1.SearchBooksRequest{
        sort: "title",
        filter: Types.encode(:struct, %{"genre" => "poetry"})
      }

      assert search!(channel, metadata, request) == ["a", "c"]
    end

    test "a nested filter", %{channel: channel, owner: owner, metadata: metadata} do
      shelve_five!(owner)

      filter = %{
        "or" => [
          %{"pages" => %{"greater_than" => 400}},
          %{"and" => [%{"genre" => %{"eq" => "poetry"}}, %{"pages" => %{"less_than" => 200}}]}
        ]
      }

      request = %V1.SearchBooksRequest{sort: "title", filter: Types.encode(:struct, filter)}

      assert search!(channel, metadata, request) == ["a", "b"]
    end

    test "an unknown or private filter field is INVALID_ARGUMENT naming filter", %{
      channel: channel,
      metadata: metadata
    } do
      for filter <- [%{"nope" => "x"}, %{"secret" => "x"}, %{"pages" => %{"near" => 3}}] do
        request = %V1.SearchBooksRequest{filter: Types.encode(:struct, filter)}

        assert_invalid(Stub.search_books(channel, request, metadata: metadata), "filter")
      end
    end

    test "a filter cannot reach records the policies hide", %{
      channel: channel,
      owner: owner,
      metadata: metadata
    } do
      shelve!(owner, "mine", %{genre: "poetry"})
      shelve!("someone else", "theirs", %{genre: "poetry"})

      request = %V1.SearchBooksRequest{filter: Types.encode(:struct, %{"genre" => "poetry"})}

      everyone = %V1.SearchBooksRequest{
        filter: Types.encode(:struct, %{"owner" => "someone else"})
      }

      assert search!(channel, metadata, request) == ["mine"]
      assert search!(channel, metadata, everyone) == []
    end

    test "page, sort and filter together", %{channel: channel, owner: owner, metadata: metadata} do
      shelve_five!(owner)

      request = %V1.PageBooksRequest{
        limit: 1,
        offset: 1,
        count: true,
        sort: "-pages",
        filter: Types.encode(:struct, %{"genre" => "poetry"})
      }

      response = page!(channel, metadata, request)

      assert {titles(response.result), response.has_more, response.count} == {["a"], false, 2}
    end

    test "a subscription sorts and filters the snapshot and every change", %{
      channel: channel,
      owner: owner,
      metadata: metadata
    } do
      shelve_five!(owner)
      test = self()

      request = %V1.WatchBooksRequest{
        sort: "-pages",
        filter: Types.encode(:struct, %{"genre" => "poetry"})
      }

      spawn_link(fn ->
        {:ok, replies} = Stub.watch_books(channel, request, metadata: metadata, timeout: 2_000)
        Enum.each(replies, &send(test, {:reply, &1}))
      end)

      snapshot = for _book <- 1..2, do: next_book()
      assert_receive {:reply, {:ok, %{synced: true}}}, 2_000

      shelve!(owner, "skipped", %{genre: "novel"})
      kept = shelve!(owner, "kept", %{genre: "poetry"})
      kept_reply = next_book()

      kept
      |> Ash.Changeset.for_update(:update, %{genre: "novel"})
      |> Ash.update!(authorize?: false)

      assert titles(snapshot) == ["c", "a"]
      assert kept_reply.title == "kept"
      assert_receive {:reply, {:ok, %{removed: true, result: %{id: id}}}}, 2_000
      assert id == kept.id
    end

    defp next_book do
      assert_receive {:reply, {:ok, %{removed: false, synced: false, result: book}}}, 2_000
      book
    end
  end

  describe "compile errors" do
    @resource """
    grpc do
      proto_message "Thing"
      fields id: 1, name: 2
    end

    attributes do
      uuid_primary_key :id, public?: true
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read, create: [:name]]

      read :by_id do
        get? true
        argument :id, :uuid, allow_nil?: false
      end

      read :unpaged

      read :offset_only do
        pagination offset?: true, countable: false, required?: false
      end

      read :by_default do
        pagination offset?: true, required?: false, paginate_by_default?: true, default_limit: 2
      end
    end
    """

    defp assert_invalid_dsl(service_body, message) do
      assert_raise DslError, message, fn ->
        ~s(package "things.v1"\nservice "Things" do\n#{service_body}\nend)
        |> compile_domain(@resource)
        |> List.wrap()
        |> AshGrpc.Schema.build()
      end
    end

    test "page on a read without pagination" do
      assert_invalid_dsl(
        "rpc INLINE, :list, :unpaged, page: [limit: 1]",
        ~r/rpc :list: `page` needs a read action with `pagination`; :unpaged has none/
      )
    end

    test "page keys the action does not allow" do
      assert_invalid_dsl(
        "rpc INLINE, :list, :offset_only, page: [limit: 1, after: 2]",
        ~r/rpc :list: `page` lists \[:after\], which read action :offset_only does not allow/
      )

      assert_invalid_dsl(
        "rpc INLINE, :list, :offset_only, page: [limit: 1, count: 2]",
        ~r/\[:count\], which read action :offset_only does not allow/
      )
    end

    test "page without a limit" do
      assert_invalid_dsl(
        "rpc INLINE, :list, :offset_only, page: [offset: 1]",
        ~r/`page` needs `:limit`/
      )
    end

    test "page, sort or filter on an action that does not read many" do
      for option <- ["page: [limit: 1]", "sort: 2", "filter: 3"] do
        assert_invalid_dsl(
          "rpc INLINE, :one, :by_id, args: [id: 1], #{option}",
          ~r/rpc :one: `page`, `sort` and `filter` need a read action that returns many/
        )

        assert_invalid_dsl(
          "rpc INLINE, :make, :create, #{option}",
          ~r/rpc :make: `page`, `sort` and `filter` need a read action that returns many/
        )
      end
    end

    test "a read that paginates by default needs page" do
      assert_invalid_dsl(
        "rpc INLINE, :list, :by_default, page: false",
        ~r/rpc :list: read action :by_default paginates by default; give the rpc a `page` option/
      )
    end

    test "page on a subscription" do
      assert_invalid_dsl(
        "subscription INLINE, :watch, :offset_only, page: [limit: 1]",
        ~r/unknown options \[:page\]/
      )
    end

    test "sort or filter numbers that collide with other request fields" do
      assert_invalid_dsl(
        "rpc INLINE, :list, :offset_only, page: [limit: 1], sort: 1",
        ~r/Field numbers repeat: \[1\]/
      )

      assert_invalid_dsl(
        "rpc INLINE, :list, :read, sort: 1, filter: 1",
        ~r/Field numbers repeat: \[1\]/
      )

      assert_invalid_dsl(
        "rpc INLINE, :list, :read, sort: 1, reserved: [1]",
        ~r/Field numbers \[1\] are reserved/
      )
    end
  end
end
