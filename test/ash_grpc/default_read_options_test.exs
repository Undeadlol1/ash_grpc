defmodule AshGrpc.DefaultReadOptionsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias Ash.Resource.Info
  alias AshGrpc.Types
  alias Mix.Tasks.AshGrpc.Gen.Protos
  alias Spark.Error.DslError

  @file_path "docs/v1.proto"

  @resource """
  grpc do
    proto_message "Doc"
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
    attribute :rank, :integer, public?: true
    attribute :note, :string, public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:title, :rank, :note], update: [:title, :rank, :note]]

    read :plain

    read :paged do
      pagination offset?: true,
                 keyset?: true,
                 countable: true,
                 required?: false,
                 default_limit: 100,
                 max_page_size: 100
    end

    read :offset_only do
      pagination offset?: true, required?: false, countable: false
    end

    read :keyset_only do
      pagination keyset?: true, required?: false, countable: false
    end

    read :uncounted do
      pagination offset?: true, keyset?: true, required?: false, countable: false
    end

    read :required do
      pagination offset?: true, required?: true, countable: false
    end

    read :by_id do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id))
    end

    read :sort_argument do
      argument :sort, :string
      filter expr(is_nil(^arg(:sort)) or title == ^arg(:sort))
    end

    read :limit_argument do
      argument :limit, :integer
      pagination offset?: true, required?: false
    end

    update :tagged do
      accept [:title]
      argument :clear_fields, :string
    end

    action :ping, :string do
      run fn _input, _context -> {:ok, "pong"} end
    end
  end
  """

  defp fields_of(domain, name, committed \\ nil) do
    previous = if committed, do: %{@file_path => committed}, else: %{}
    [package] = AshGrpc.Schema.build([domain], previous: previous)

    message =
      package.services
      |> Enum.flat_map(& &1.rpcs)
      |> Enum.flat_map(&[&1.request, &1.response])
      |> Enum.find(&(&1.name == name))

    %{fields: Enum.map(message.fields, &{&1.name, &1.number}), reserved: message.reserved}
  end

  defp request(domain, name \\ "ListDocsRequest", committed \\ nil),
    do: fields_of(domain, name, committed).fields

  defp one(rpcs, resource \\ @resource),
    do: compile_domain(~s(package "docs.v1"\nservice "Docs" do\n #{rpcs}\n end), resource)

  defp generate(domain, committed \\ nil) do
    previous = if committed, do: %{@file_path => committed}, else: %{}
    [{@file_path, text}] = AshGrpc.Proto.render([domain], previous: previous)
    text
  end

  describe "a read that returns many" do
    test "GIVEN no options WHEN built THEN the request has sort and filter" do
      assert request(one("rpc INLINE, :list_docs, :plain")) == [sort: 1, filter: 2]
    end

    test "GIVEN a paginated action WHEN built THEN the request has exactly the page keys it allows, then sort and filter" do
      assert request(one("rpc INLINE, :list_docs, :paged")) ==
               [limit: 1, offset: 2, after: 3, before: 4, count: 5, sort: 6, filter: 7]
    end

    test "GIVEN a paginated action WHEN built THEN the response says how to go on" do
      response = fields_of(one("rpc INLINE, :list_docs, :paged"), "ListDocsResponse").fields

      assert response == [result: 1, has_more: 3, count: 4, first_keyset: 5, last_keyset: 6]
    end

    test "GIVEN an offset-only action WHEN built THEN there is no keyset or count" do
      assert request(one("rpc INLINE, :list_docs, :offset_only")) ==
               [limit: 1, offset: 2, sort: 3, filter: 4]
    end

    test "GIVEN a keyset-only action WHEN built THEN there is no offset or count" do
      assert request(one("rpc INLINE, :list_docs, :keyset_only")) ==
               [limit: 1, after: 2, before: 3, sort: 4, filter: 5]
    end

    test "GIVEN an action that is not countable WHEN built THEN there is no count" do
      assert request(one("rpc INLINE, :list_docs, :uncounted")) ==
               [limit: 1, offset: 2, after: 3, before: 4, sort: 5, filter: 6]
    end

    test "GIVEN an action that requires pagination and no page option WHEN built THEN it is paged by default" do
      assert request(one("rpc INLINE, :list_docs, :required")) ==
               [limit: 1, offset: 2, sort: 3, filter: 4]
    end

    test "GIVEN page: false on an action that requires pagination WHEN built THEN the old error stays" do
      error =
        assert_raise DslError, fn ->
          request(one("rpc INLINE, :list_docs, :required, page: false"))
        end

      assert error.message =~ "requires pagination; give the rpc a `page` option"
    end

    test "GIVEN a plain read WHEN built THEN there is no paging" do
      refute Keyword.has_key?(request(one("rpc INLINE, :list_docs, :plain")), :limit)

      assert fields_of(one("rpc INLINE, :list_docs, :plain"), "ListDocsResponse").fields == [
               result: 1
             ]
    end
  end

  describe "opting out" do
    test "GIVEN sort: false WHEN built THEN there is no sort" do
      assert request(one("rpc INLINE, :list_docs, :plain, sort: false")) == [filter: 1]
    end

    test "GIVEN filter: false WHEN built THEN there is no filter" do
      assert request(one("rpc INLINE, :list_docs, :plain, filter: false")) == [sort: 1]
    end

    test "GIVEN page: false WHEN built THEN there are no page fields and no has_more" do
      domain = one("rpc INLINE, :list_docs, :paged, page: false")

      assert request(domain) == [sort: 1, filter: 2]
      assert fields_of(domain, "ListDocsResponse").fields == [result: 1]
    end

    test "GIVEN sort: false WHEN a committed file had it THEN its number stays reserved" do
      committed = generate(one("rpc INLINE, :list_docs, :plain"))
      domain = one("rpc INLINE, :list_docs, :plain, sort: false")

      assert fields_of(domain, "ListDocsRequest", committed) ==
               %{fields: [filter: 2], reserved: [1]}
    end

    test "GIVEN page: false WHEN a committed file had page fields THEN their numbers stay reserved" do
      committed = generate(one("rpc INLINE, :list_docs, :offset_only"))
      domain = one("rpc INLINE, :list_docs, :offset_only, page: false")

      assert fields_of(domain, "ListDocsRequest", committed) ==
               %{fields: [sort: 3, filter: 4], reserved: [1, 2]}
    end

    test "GIVEN options turned on later WHEN a committed file lacks them THEN they take new numbers above the rest" do
      committed = generate(one("rpc INLINE, :list_docs, :plain, sort: false, filter: false"))

      assert request(one("rpc INLINE, :list_docs, :plain"), "ListDocsRequest", committed) ==
               [sort: 1, filter: 2]
    end
  end

  describe "explicit options" do
    test "GIVEN today's explicit numbers WHEN built THEN they are kept byte for byte" do
      domain =
        one(
          "rpc INLINE, :list_docs, :paged, page: [limit: 1, offset: 2, after: 3, before: 4, count: 5], sort: 6, filter: 7"
        )

      assert request(domain) ==
               [limit: 1, offset: 2, after: 3, before: 4, count: 5, sort: 6, filter: 7]
    end

    test "GIVEN true WHEN built THEN sort, filter and page are numbered automatically" do
      domain = one("rpc INLINE, :list_docs, :offset_only, page: true, sort: true, filter: true")

      assert request(domain) == [limit: 1, offset: 2, sort: 3, filter: 4]
    end

    test "GIVEN page names without numbers WHEN built THEN only those are added, numbered automatically" do
      domain = one("rpc INLINE, :list_docs, :paged, page: [:limit, :offset]")

      assert request(domain) == [limit: 1, offset: 2, sort: 3, filter: 4]
    end

    test "GIVEN page names and numbers mixed WHEN built THEN the written numbers win" do
      domain = one("rpc INLINE, :list_docs, :paged, page: [:limit, offset: 9], sort: 3")

      assert request(domain) == [limit: 1, offset: 9, sort: 3, filter: 2]
    end

    test "GIVEN page names the action does not allow WHEN built THEN the build stops" do
      error =
        assert_raise DslError, fn ->
          request(one("rpc INLINE, :list_docs, :offset_only, page: [:limit, :after]"))
        end

      assert error.message =~ "does not allow"
    end

    test "GIVEN page names without limit WHEN built THEN the build stops" do
      error =
        assert_raise DslError, fn ->
          request(one("rpc INLINE, :list_docs, :paged, page: [:offset]"))
        end

      assert error.message =~ "limit"
    end
  end

  describe "rpcs that are not a read returning many" do
    test "GIVEN a create WHEN built THEN there is no sort, filter, page or clear_fields" do
      assert request(one("rpc INLINE, :make_doc, :create"), "MakeDocRequest") ==
               [title: 1, rank: 2, note: 3]
    end

    test "GIVEN a destroy WHEN built THEN there is no sort, filter or page" do
      assert request(one("rpc INLINE, :drop_doc, :destroy"), "DropDocRequest") == [id: 1]
    end

    test "GIVEN a generic action WHEN built THEN there is no sort, filter or page" do
      assert request(one("rpc INLINE, :ping, :ping"), "PingRequest") == []
    end

    test "GIVEN a get-one read WHEN built THEN there is no sort, filter or page" do
      assert request(one("rpc INLINE, :find_doc, :by_id"), "FindDocRequest") == [id: 1]
    end

    test "GIVEN a get-one read WHEN sort: true is asked THEN the build stops as before" do
      error =
        assert_raise DslError, fn ->
          request(one("rpc INLINE, :find_doc, :by_id, sort: true"), "FindDocRequest")
        end

      assert error.message =~ "need a read action that returns many"
    end

    test "GIVEN a create WHEN filter: true is asked THEN the build stops as before" do
      error =
        assert_raise DslError, fn ->
          request(one("rpc INLINE, :make_doc, :create, filter: true"))
        end

      assert error.message =~ "need a read action that returns many"
    end

    test "GIVEN opt-outs on a create WHEN built THEN they are accepted" do
      domain = one("rpc INLINE, :make_doc, :create, sort: false, filter: false, page: false")

      assert request(domain, "MakeDocRequest") == [title: 1, rank: 2, note: 3]
    end
  end

  describe "clear_fields" do
    test "GIVEN an update WHEN built THEN clear_fields comes after the inputs" do
      assert request(one("rpc INLINE, :change_doc, :update"), "ChangeDocRequest") ==
               [id: 1, title: 2, rank: 3, note: 4, clear_fields: 5]
    end

    test "GIVEN clear_fields: false on an update WHEN built THEN it is not added" do
      assert request(
               one("rpc INLINE, :change_doc, :update, clear_fields: false"),
               "ChangeDocRequest"
             ) == [id: 1, title: 2, rank: 3, note: 4]
    end

    test "GIVEN clear_fields: true on a create WHEN built THEN it is added and numbered" do
      assert request(
               one("rpc INLINE, :make_doc, :create, clear_fields: true"),
               "MakeDocRequest"
             ) == [title: 1, rank: 2, note: 3, clear_fields: 4]
    end

    test "GIVEN an explicit clear_fields number WHEN built THEN it is unchanged" do
      assert request(
               one("rpc INLINE, :change_doc, :update, clear_fields: 9"),
               "ChangeDocRequest"
             ) == [id: 1, title: 2, rank: 3, note: 4, clear_fields: 9]
    end

    test "GIVEN clear_fields: false WHEN a committed file had it THEN its number stays reserved" do
      committed = generate(one("rpc INLINE, :change_doc, :update"))
      domain = one("rpc INLINE, :change_doc, :update, clear_fields: false")

      assert fields_of(domain, "ChangeDocRequest", committed).reserved == [5]
    end
  end

  describe "subscriptions" do
    test "GIVEN a subscription WHEN built THEN it has sort and filter and never paging" do
      domain = one("subscription INLINE, :watch_docs, :read")

      assert request(domain, "WatchDocsRequest") == [sort: 1, filter: 2]
    end

    test "GIVEN opt-outs on a subscription WHEN built THEN the fields are gone" do
      domain = one("subscription INLINE, :watch_docs, :read, sort: false, filter: false")

      assert request(domain, "WatchDocsRequest") == []
    end

    test "GIVEN a subscription over a paginated action WHEN built THEN the build stops as before" do
      error =
        assert_raise DslError, fn ->
          request(one("subscription INLINE, :watch_docs, :required"), "WatchDocsRequest")
        end

      assert error.message =~ "requires pagination; a subscription sends every record"
    end
  end

  describe "a name clash with a default field" do
    test "GIVEN an action argument called sort WHEN built THEN the build names the rpc, the input and the opt-out" do
      error =
        assert_raise DslError, fn ->
          request(one("rpc INLINE, :list_docs, :sort_argument"))
        end

      assert error.message =~ "rpc :list_docs"
      assert error.message =~ ":sort"
      assert error.message =~ "`sort: false`"
    end

    test "GIVEN an argument called limit on a paginated read WHEN built THEN the build names the opt-out" do
      error =
        assert_raise DslError, fn ->
          request(one("rpc INLINE, :list_docs, :limit_argument"))
        end

      assert error.message =~ "rpc :list_docs"
      assert error.message =~ ":limit"
      assert error.message =~ "`page: false`"
    end

    test "GIVEN an argument called clear_fields on an update WHEN built THEN the build names the opt-out" do
      error =
        assert_raise DslError, fn ->
          request(one("rpc INLINE, :tag_doc, :tagged"), "TagDocRequest")
        end

      assert error.message =~ "rpc :tag_doc"
      assert error.message =~ "`clear_fields: false`"
    end

    test "GIVEN the opt-out WHEN built THEN the argument is a request field" do
      domain = one("rpc INLINE, :list_docs, :sort_argument, sort: false")

      assert request(domain) == [sort: 1, filter: 2]
    end

    test "GIVEN the option written explicitly WHEN it clashes with an input THEN the duplicate-name error stays" do
      error =
        assert_raise DslError, fn ->
          request(one("rpc INLINE, :list_docs, :sort_argument, sort: 5"))
        end

      assert error.message =~ "Field names repeat"
    end
  end

  describe "over a real connection" do
    @describetag :tmp_dir

    setup context do
      previous = Application.get_env(:ash_grpc, :proto_output)
      Application.put_env(:ash_grpc, :proto_output, context.tmp_dir)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_grpc, :proto_output, previous),
          else: Application.delete_env(:ash_grpc, :proto_output)
      end)

      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(shell) end)
    end

    @served_rpcs """
    rpc #PREFIX.Doc, :list_docs, :plain
    rpc #PREFIX.Doc, :page_docs, :paged
    rpc #PREFIX.Doc, :make_doc, :create
    rpc #PREFIX.Doc, :change_doc, :update
    rpc #PREFIX.Doc, :keep_doc, :update, clear_fields: false
    rpc #PREFIX.Doc, :tagged_docs, :sort_argument, sort: false
    subscription #PREFIX.Doc, :watch_docs, :read
    """

    defp serve(use_opts \\ "", rpcs \\ @served_rpcs, resource \\ @resource) do
      prefix = "AshGrpc.Compiled.Served#{System.unique_integer([:positive])}"

      compile("""
      defmodule #{prefix}.Doc do
        use Ash.Resource, domain: #{prefix}.Domain, data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrpc.Resource]#{use_opts}

        #{resource}
      end

      defmodule #{prefix}.Domain do
        use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

        resources do
          resource #{prefix}.Doc
        end

        grpc do
          package "docs.v1"

          service "Docs" do
            #{String.replace(rpcs, "#PREFIX", prefix)}
          end
        end
      end
      """)

      endpoint = compile_endpoint(Module.concat([prefix, "Domain"]))

      %{
        endpoint: endpoint,
        doc: Module.concat([prefix, "Doc"]),
        channel: start(endpoint),
        stub: Module.concat([endpoint, "Docs", "V1", "Docs", "Stub"]),
        message: &Module.concat([endpoint, "Docs", "V1", &1]),
        metadata: signed_in("reader")
      }
    end

    defp write!(doc, attrs) do
      doc |> Ash.Changeset.for_create(:create, attrs) |> Ash.create!()
    end

    defp call(server, rpc, request \\ []) do
      name = rpc |> Atom.to_string() |> Macro.camelize()
      message = struct!(server.message.(name <> "Request"), request)
      apply(server.stub, rpc, [server.channel, message, [metadata: server.metadata]])
    end

    defp titles(docs), do: Enum.map(docs, & &1.title)

    defp seed(server, titles_and_ranks),
      do:
        for(
          {title, rank} <- titles_and_ranks,
          do: write!(server.doc, %{title: title, rank: rank})
        )

    defp filter(map), do: Types.encode(:struct, map)

    defp assert_invalid(result) do
      assert {:error, %GRPC.RPCError{status: status}} = result
      assert status == GRPC.Status.invalid_argument()
    end

    test "GIVEN a client that sends none of the new fields WHEN it lists THEN it gets every record" do
      server = serve()
      seed(server, [{"b", 2}, {"a", 1}, {"c", 3}])

      assert {:ok, %{result: docs}} = call(server, :list_docs)
      assert Enum.sort(titles(docs)) == ["a", "b", "c"]
    end

    test "GIVEN no options written WHEN a client sorts THEN the records come in that order" do
      server = serve()
      seed(server, [{"b", 2}, {"a", 1}, {"c", 3}])

      assert {:ok, %{result: docs}} = call(server, :list_docs, sort: "-rank")
      assert titles(docs) == ["c", "b", "a"]
    end

    test "GIVEN no options written WHEN a client filters THEN only the matches come back" do
      server = serve()
      seed(server, [{"b", 2}, {"a", 1}, {"c", 3}])

      assert {:ok, %{result: docs}} = call(server, :list_docs, filter: filter(%{"rank" => 2}))
      assert titles(docs) == ["b"]
    end

    test "GIVEN no options written WHEN a client pages THEN it gets a page and has_more" do
      server = serve()
      seed(server, [{"a", 1}, {"b", 2}, {"c", 3}])

      assert {:ok, first} = call(server, :page_docs, limit: 2, sort: "rank")
      assert {:ok, last} = call(server, :page_docs, limit: 2, offset: 2, sort: "rank")

      assert {titles(first.result), first.has_more} == {["a", "b"], true}
      assert {titles(last.result), last.has_more} == {["c"], false}
    end

    test "GIVEN a paged rpc WHEN the client sends no page fields THEN it gets the records and has_more false" do
      server = serve()
      seed(server, [{"a", 1}, {"b", 2}])

      assert {:ok, reply} = call(server, :page_docs)
      assert {length(reply.result), reply.has_more} == {2, false}
    end

    test "GIVEN a private field WHEN a client sorts or filters by it THEN the call is INVALID_ARGUMENT" do
      server = serve()
      seed(server, [{"a", 1}])

      assert_invalid(call(server, :list_docs, sort: "secret"))
      assert_invalid(call(server, :list_docs, filter: filter(%{"secret" => "x"})))
      assert_invalid(call(server, :list_docs, sort: "nope"))
    end

    test "GIVEN 250 records WHEN a client pages with the default paging fields THEN each record comes back once" do
      server = serve()
      seed(server, for(rank <- 0..249, do: {"doc#{rank}", rank}))

      ranks =
        0
        |> Stream.unfold(fn
          nil ->
            nil

          offset ->
            assert {:ok, reply} =
                     call(server, :page_docs, limit: 100, offset: offset, sort: "rank")

            {Enum.map(reply.result, & &1.rank), if(reply.has_more, do: offset + 100)}
        end)
        |> Enum.to_list()
        |> List.flatten()

      assert ranks == Enum.to_list(0..249)
    end

    test "GIVEN an update WHEN the client lists a field in clear_fields THEN that value is cleared" do
      server = serve()
      [doc] = seed(server, [{"a", 1}])
      Ash.update!(doc, %{note: "keep me?"})

      assert {:ok, %{result: updated}} =
               call(server, :change_doc, id: doc.id, title: "z", clear_fields: ["note"])

      assert {updated.title, updated.note} == {"z", nil}
    end

    test "GIVEN clear_fields: false WHEN the request message is built THEN it has no such field" do
      server = serve()

      refute Map.has_key?(struct(server.message.("KeepDocRequest")), :clear_fields)
      assert Map.has_key?(struct(server.message.("ChangeDocRequest")), :clear_fields)
    end

    test "GIVEN sort: false WHEN an action argument is called sort THEN the argument works" do
      server = serve()
      seed(server, [{"a", 1}, {"b", 2}])

      assert {:ok, %{result: docs}} = call(server, :tagged_docs, sort: "b")
      assert titles(docs) == ["b"]
    end

    test "GIVEN a create WHEN the request message is built THEN it has no sort, filter or page fields" do
      server = serve()
      keys = "MakeDocRequest" |> server.message.() |> struct() |> Map.keys()

      refute Enum.any?(keys, &(&1 in [:sort, :filter, :limit, :offset, :clear_fields]))
    end

    defp watching(server, request \\ []) do
      test = self()

      spawn_link(fn ->
        message = struct!(server.message.("WatchDocsRequest"), request)

        {:ok, replies} =
          server.stub.watch_docs(server.channel, message, metadata: server.metadata)

        Enum.each(replies, &send(test, {:reply, &1}))
      end)
    end

    defp next_reply do
      assert_receive {:reply, {:ok, reply}}, 2_000
      reply
    end

    defp drain_snapshot do
      case next_reply() do
        %{synced: true} -> :ok
        _record -> drain_snapshot()
      end
    end

    test "GIVEN a subscription WHEN a client filters THEN the snapshot and the changes honour it" do
      server = serve()
      seed(server, [{"low", 1}, {"high", 2}])
      watching(server, filter: filter(%{"rank" => 2}))

      assert %{result: %{title: "high"}} = next_reply()
      assert %{synced: true} = next_reply()

      write!(server.doc, %{title: "low again", rank: 1})
      write!(server.doc, %{title: "high again", rank: 2})

      assert %{result: %{title: "high again"}, removed: false} = next_reply()
      refute_receive {:reply, _}, 200
    end

    test "GIVEN a subscription WHEN a client sorts THEN the snapshot comes in that order" do
      server = serve()
      seed(server, [{"a", 1}, {"b", 2}])
      watching(server, sort: "-rank")

      assert %{result: %{title: "b"}} = next_reply()
      assert %{result: %{title: "a"}} = next_reply()
    end

    test "GIVEN a subscription WHEN its request message is built THEN it has no page fields" do
      server = serve()
      keys = "WatchDocsRequest" |> server.message.() |> struct() |> Map.keys()

      assert Enum.sort(keys -- [:__protobuf__, :__unknown_fields__, :__struct__]) == [
               :filter,
               :sort
             ]
    end

    test "GIVEN a resource with only the extension WHEN a subscription is open THEN a change reaches it" do
      server = serve()
      assert Info.notifiers(server.doc) == [AshGrpc.Notifier]
      watching(server)
      drain_snapshot()

      write!(server.doc, %{title: "fresh", rank: 1})

      assert %{result: %{title: "fresh"}, removed: false} = next_reply()
    end

    test "GIVEN a resource that also lists the notifier in simple_notifiers WHEN a record is written THEN the subscription is told once" do
      server = serve(", simple_notifiers: [AshGrpc.Notifier]")
      assert Info.notifiers(server.doc) == [AshGrpc.Notifier]
      watching(server)
      drain_snapshot()

      write!(server.doc, %{title: "fresh", rank: 1})

      assert %{result: %{title: "fresh"}} = next_reply()
      refute_receive {:reply, _}, 300
    end

    test "GIVEN a resource that lists the notifier in notifiers WHEN a record is written THEN the subscription is told once" do
      server = serve(", notifiers: [AshGrpc.Notifier]")
      assert Info.notifiers(server.doc) == [AshGrpc.Notifier]
      watching(server)
      drain_snapshot()

      write!(server.doc, %{title: "fresh", rank: 1})

      assert %{result: %{title: "fresh"}} = next_reply()
      refute_receive {:reply, _}, 300
    end

    test "GIVEN a resource with the extension and no subscription WHEN a record is written THEN the write works" do
      server = serve("", "rpc #PREFIX.Doc, :list_docs, :plain")

      assert %{title: "plain"} = write!(server.doc, %{title: "plain", rank: 1})
      assert {:ok, %{result: [%{title: "plain"}]}} = call(server, :list_docs)
    end

    test "GIVEN a domain using every default WHEN gen.protos runs twice THEN the second run writes nothing and --check passes",
         %{tmp_dir: dir} do
      server = serve()
      flags = ["--endpoint", inspect(server.endpoint), "--output", dir]

      Protos.run(flags)
      written = File.read!(Path.join(dir, @file_path))
      assert Protos.run(flags ++ ["--check"]) == :ok
      Protos.run(flags)

      assert File.read!(Path.join(dir, @file_path)) == written
      assert written =~ "message PageDocsRequest {"
      assert written =~ "optional string sort ="
    end
  end

  describe "sensitive and private fields without a fields list" do
    @describetag :tmp_dir

    @secrets """
    grpc do
      proto_message "Vault"
    end

    attributes do
      uuid_primary_key :id, public?: true
      attribute :title, :string, public?: true
      attribute :internal, :string
      attribute :token, :string, public?: true, sensitive?: true
    end

    actions do
      defaults [:read]

      create :create do
        accept [:title]
        change set_attribute(:internal, "private-secret-xyz")
        change set_attribute(:token, "sensitive-secret-abc")
      end
    end
    """

    setup context do
      Application.put_env(:ash_grpc, :proto_output, context.tmp_dir)
      on_exit(fn -> Application.delete_env(:ash_grpc, :proto_output) end)
    end

    test "GIVEN a private and a sensitive attribute with values WHEN created and listed over gRPC THEN neither value is sent" do
      server =
        serve(
          "",
          "rpc #PREFIX.Doc, :make_doc, :create\nrpc #PREFIX.Doc, :list_docs, :read",
          @secrets
        )

      assert {:ok, %{result: created} = created_reply} = call(server, :make_doc, title: "t")
      assert {:ok, %{result: [listed]} = list_reply} = call(server, :list_docs)

      for message <- [created, listed] do
        refute Map.has_key?(message, :internal)
        refute Map.has_key?(message, :token)
      end

      for reply <- [created_reply, list_reply] do
        bytes = reply.__struct__.encode(reply)
        refute bytes =~ "private-secret-xyz"
        refute bytes =~ "sensitive-secret-abc"
      end
    end
  end
end
