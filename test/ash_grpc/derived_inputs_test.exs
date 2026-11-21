defmodule AshGrpc.DerivedInputsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias Mix.Tasks.AshGrpc.Gen.Protos
  alias Spark.Error.DslError

  @file_path "docs/v1.proto"
  @attributes """
  uuid_primary_key :id, public?: true
  attribute :title, :string, public?: true
  attribute :body, :string, public?: true
  attribute :slug, :string, public?: true
  attribute :secret, :string
  """

  defp domain(rpcs, actions, opts \\ []) do
    attributes = Keyword.get(opts, :attributes, @attributes)

    resource = """
    grpc do
      proto_message "Doc"
    end

    attributes do
      #{attributes}
    end

    actions do
      defaults [:read]
      #{actions}
    end
    """

    compile_domain(
      ~s(package "docs.v1"\nservice "Docs" do\n #{rpcs}\n end),
      resource,
      Keyword.get(opts, :use, "")
    )
  end

  defp generate(domain, committed \\ nil) do
    previous = if committed, do: %{@file_path => committed}, else: %{}
    [{@file_path, text}] = AshGrpc.Proto.render([domain], previous: previous)
    text
  end

  defp request(domain, name, committed \\ nil) do
    previous = if committed, do: %{@file_path => committed}, else: %{}
    [package] = AshGrpc.Schema.build([domain], previous: previous)
    found = Enum.find(package.messages, &(&1.name == name)) || request_of(package, name)
    %{fields: Enum.map(found.fields, &{&1.name, &1.number}), reserved: found.reserved}
  end

  defp request_of(package, name) do
    package.services
    |> Enum.flat_map(& &1.rpcs)
    |> Enum.map(& &1.request)
    |> Enum.find(&(&1.name == name))
  end

  defp create_domain(accept, extra \\ "") do
    domain(
      "rpc INLINE, :make_doc, :make",
      """
      create :make do
        accept #{inspect(accept)}
        #{extra}
      end
      """
    )
  end

  test "GIVEN a create rpc without args WHEN built THEN the request has the accepted attributes then the public arguments, numbered from 1" do
    domain = create_domain([:title, :body], "argument :tag, :string")

    assert request(domain, "MakeDocRequest").fields == [title: 1, body: 2, tag: 3]
  end

  test "GIVEN a create that accepts a private attribute WHEN built THEN the request leaves it out" do
    domain = create_domain([:title, :secret])

    assert request(domain, "MakeDocRequest").fields == [title: 1]
  end

  test "GIVEN an update rpc without args WHEN built THEN the primary key comes first, then accepted attributes, then arguments" do
    domain =
      domain(
        "rpc INLINE, :change_doc, :change, clear_fields: false",
        """
        update :change do
          accept [:title]
          argument :tag, :string
        end
        """
      )

    assert request(domain, "ChangeDocRequest").fields == [id: 1, title: 2, tag: 3]
  end

  test "GIVEN a destroy rpc without args WHEN built THEN the request has the primary key then the arguments" do
    domain =
      domain(
        "rpc INLINE, :remove_doc, :remove",
        "destroy :remove do\n argument :why, :string\n end"
      )

    assert request(domain, "RemoveDocRequest").fields == [id: 1, why: 2]
  end

  test "GIVEN a composite primary key WHEN an update rpc has no args THEN every key field leads the request" do
    domain =
      domain(
        "rpc INLINE, :change_doc, :change, clear_fields: false",
        "update :change do\n accept [:title]\n end",
        attributes: """
        attribute :org, :string, primary_key?: true, allow_nil?: false, public?: true
        attribute :code, :string, primary_key?: true, allow_nil?: false, public?: true
        attribute :title, :string, public?: true
        """
      )

    assert request(domain, "ChangeDocRequest").fields == [org: 1, code: 2, title: 3]
  end

  test "GIVEN a read rpc without args WHEN built THEN the request has only the public arguments and no primary key" do
    domain =
      domain(
        "rpc INLINE, :search_docs, :search, sort: false, filter: false, page: false",
        """
        read :search do
          argument :word, :string, allow_nil?: false
          argument :limit_to, :integer
        end
        """
      )

    assert request(domain, "SearchDocsRequest").fields == [word: 1, limit_to: 2]
  end

  test "GIVEN a generic action without args WHEN built THEN the request has its public arguments" do
    domain =
      domain(
        "rpc INLINE, :shout_doc, :shout",
        """
        action :shout, :string do
          argument :text, :string, allow_nil?: false
          run fn input, _context -> {:ok, input.arguments.text} end
        end
        """
      )

    assert request(domain, "ShoutDocRequest").fields == [text: 1]
  end

  test "GIVEN a subscription without args WHEN built THEN the request has the read action's public arguments" do
    domain =
      domain(
        "subscription INLINE, :watch_docs, :search, sort: false, filter: false",
        "read :search do\n argument :word, :string, allow_nil?: false\n end",
        use: ", simple_notifiers: [AshGrpc.Notifier]"
      )

    assert request(domain, "WatchDocsRequest").fields == [word: 1]
  end

  test "GIVEN args: [] WHEN the action accepts attributes THEN the request is empty" do
    domain =
      domain(
        "rpc INLINE, :make_doc, :make, args: []",
        "create :make do\n accept [:title]\n argument :tag, :string\n end"
      )

    assert request(domain, "MakeDocRequest").fields == []
  end

  test "GIVEN args listing names only WHEN built THEN exactly those inputs are numbered in the order listed" do
    domain =
      domain(
        "rpc INLINE, :make_doc, :make, args: [:tag, :title]",
        "create :make do\n accept [:title, :body]\n argument :tag, :string\n end"
      )

    assert request(domain, "MakeDocRequest").fields == [tag: 1, title: 2]
  end

  test "GIVEN args mixing names and numbered names WHEN built THEN the numbered one keeps its number" do
    domain =
      domain(
        "rpc INLINE, :change_doc, :change, args: [:id, title: 7, body: 2], clear_fields: false",
        "update :change do\n accept [:title, :body]\n end"
      )

    assert request(domain, "ChangeDocRequest").fields == [id: 1, title: 7, body: 2]
  end

  test "GIVEN args naming something the action does not have WHEN built THEN the build stops as before" do
    assert_raise DslError, ~r/:nope, which is not an argument/, fn ->
      request(
        domain(
          "rpc INLINE, :make_doc, :make, args: [:nope]",
          "create :make do\n accept [:title]\n end"
        ),
        "MakeDocRequest"
      )
    end
  end

  test "GIVEN a private argument WHEN args are derived THEN it is left out" do
    domain = create_domain([:title], "argument :hidden, :string, public?: false")

    assert request(domain, "MakeDocRequest").fields == [title: 1]
  end

  test "GIVEN an optional argument with no protobuf mapping WHEN args are derived THEN it is left out" do
    domain = create_domain([:title], "argument :blob, :term")

    assert request(domain, "MakeDocRequest").fields == [title: 1]
  end

  test "GIVEN a required argument with no protobuf mapping WHEN args are derived THEN the build stops naming the rpc, the input and an explicit args list" do
    domain = create_domain([:title], "argument :blob, :term, allow_nil?: false")

    error = assert_raise DslError, fn -> request(domain, "MakeDocRequest") end

    assert error.message =~ "rpc :make_doc"
    assert error.message =~ ":blob"
    assert error.message =~ "args:"
  end

  test "GIVEN an argument and an attribute that share a name WHEN args are derived THEN the request has the input once" do
    domain = create_domain([:title], "argument :body, :string")

    assert request(domain, "MakeDocRequest").fields == [title: 1, body: 2]
  end

  test "GIVEN inputs named like response fields WHEN args are derived THEN they work in the request" do
    domain = create_domain([:title], "argument :result, :string\n argument :meta, :string")

    assert request(domain, "MakeDocRequest").fields == [title: 1, result: 2, meta: 3]
  end

  test "GIVEN a committed request WHEN an attribute is added to accept THEN old numbers stay and the new one is appended" do
    committed = generate(create_domain([:title, :body]))

    assert Enum.sort_by(
             request(create_domain([:slug, :title, :body]), "MakeDocRequest", committed).fields,
             &elem(&1, 1)
           ) ==
             [title: 1, body: 2, slug: 3]
  end

  test "GIVEN a committed request WHEN an attribute leaves accept THEN its number is reserved and a re-added one gets a new number" do
    first = generate(create_domain([:title, :body]))
    removed = generate(create_domain([:title]), first)

    assert request(create_domain([:title]), "MakeDocRequest", first) ==
             %{fields: [title: 1], reserved: [2]}

    assert request(create_domain([:title, :body]), "MakeDocRequest", removed) ==
             %{fields: [title: 1, body: 3], reserved: [2]}
  end

  test "GIVEN no committed file WHEN an rpc without args is built THEN the numbers start at 1" do
    assert request(create_domain([:title, :body]), "MakeDocRequest").fields ==
             [title: 1, body: 2]
  end

  test "GIVEN an unchanged domain WHEN it is rendered again from its own output THEN the text is identical" do
    first = generate(create_domain([:title, :body], "argument :tag, :string"))
    again = generate(create_domain([:title, :body], "argument :tag, :string"), first)

    assert again == first
  end

  test "GIVEN explicit page, sort and filter numbers WHEN inputs are derived THEN the inputs avoid them" do
    domain =
      domain(
        "rpc INLINE, :search_docs, :search, page: [limit: 1, offset: 3], sort: 2, filter: 5",
        """
        read :search do
          pagination offset?: true, required?: false
          argument :word, :string
          argument :lang, :string
          argument :kind, :string
        end
        """
      )

    fields = request(domain, "SearchDocsRequest").fields

    assert Keyword.take(fields, [:word, :lang, :kind]) == [word: 4, lang: 6, kind: 7]
    assert fields |> Keyword.values() |> Enum.uniq() |> length() == length(fields)
  end

  test "GIVEN an explicit clear_fields number WHEN inputs are derived THEN the inputs avoid it" do
    domain =
      domain(
        "rpc INLINE, :make_doc, :make, clear_fields: 1",
        "create :make do\n accept [:title, :body]\n end"
      )

    assert request(domain, "MakeDocRequest").fields == [title: 2, body: 3, clear_fields: 1]
  end

  test "GIVEN an action accepting 60 attributes WHEN args are derived THEN all are numbered 1..60" do
    names = for n <- 1..60, do: :"a#{n}"
    attributes = Enum.map_join(names, "\n", &"attribute #{inspect(&1)}, :string, public?: true")

    domain =
      domain(
        "rpc INLINE, :make_doc, :make",
        "create :make do\n accept #{inspect(names, limit: :infinity)}\n end",
        attributes: "uuid_primary_key :id, public?: true\n" <> attributes
      )

    assert request(domain, "MakeDocRequest").fields == Enum.with_index(names, 1)
  end

  test "GIVEN no proto_output WHEN an rpc has no args and inputs THEN the build stops with the config hint" do
    error =
      assert_raise DslError, fn ->
        AshGrpc.Schema.build([create_domain([:title])])
      end

    assert error.message =~ ~s(config :ash_grpc, proto_output: "priv/protos")
  end

  describe "over the wire" do
    setup do
      previous = Application.get_env(:ash_grpc, :proto_output)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ash_grpc, :proto_output, previous),
          else: Application.delete_env(:ash_grpc, :proto_output)
      end)

      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(shell) end)
    end

    @describetag :tmp_dir

    test "GIVEN rpcs without args WHEN a doc is created, updated and destroyed THEN each call uses the derived inputs",
         %{
           tmp_dir: dir
         } do
      prefix = "AshGrpc.Compiled.Derived#{System.unique_integer([:positive])}"

      compile("""
      defmodule #{prefix}.Doc do
        use Ash.Resource, domain: #{prefix}.Domain, data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrpc.Resource]

        attributes do
          uuid_primary_key :id, public?: true
          attribute :title, :string, public?: true
          attribute :body, :string, public?: true
        end

        actions do
          defaults [:read, :destroy, create: [:title, :body], update: [:title, :body]]
        end
      end

      defmodule #{prefix}.Domain do
        use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

        resources do
          resource #{prefix}.Doc
        end

        grpc do
          package "docs.v1"

          service "Docs" do
            rpc #{prefix}.Doc, :create_doc, :create
            rpc #{prefix}.Doc, :update_doc, :update
            rpc #{prefix}.Doc, :destroy_doc, :destroy
            rpc #{prefix}.Doc, :list_docs, :read, sort: false, filter: false, page: false
          end
        end
      end
      """)

      Application.put_env(:ash_grpc, :proto_output, dir)
      endpoint = compile_endpoint(Module.concat([prefix, "Domain"]))
      Protos.run(["--endpoint", inspect(endpoint), "--output", dir])
      written = File.read!(Path.join(dir, @file_path))

      assert written =~ "optional string title = 1;"
      assert written =~ "optional string body = 2;"
      assert Protos.run(["--endpoint", inspect(endpoint), "--output", dir, "--check"]) == :ok
      Protos.run(["--endpoint", inspect(endpoint), "--output", dir])
      assert File.read!(Path.join(dir, @file_path)) == written

      channel = start(endpoint)
      stub = Module.concat([endpoint, "Docs", "V1", "Docs", "Stub"])
      message = &Module.concat([endpoint, "Docs", "V1", &1])
      metadata = signed_in("writer")

      assert {:ok, %{result: created}} =
               stub.create_doc(
                 channel,
                 struct!(message.("CreateDocRequest"), title: "a", body: "b"),
                 metadata: metadata
               )

      assert %{title: "a", body: "b"} = created

      assert {:ok, %{result: updated}} =
               stub.update_doc(
                 channel,
                 struct!(message.("UpdateDocRequest"), id: created.id, title: "c"),
                 metadata: metadata
               )

      assert %{title: "c", body: "b"} = updated

      assert {:ok, _} =
               stub.destroy_doc(channel, struct!(message.("DestroyDocRequest"), id: created.id),
                 metadata: metadata
               )

      assert {:ok, %{result: []}} =
               stub.list_docs(channel, struct!(message.("ListDocsRequest"), []),
                 metadata: metadata
               )
    end
  end
end
