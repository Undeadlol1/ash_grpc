defmodule AshGrpc.DefaultFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias Mix.Tasks.AshGrpc.Gen.Protos
  alias Spark.Error.DslError

  @file_path "notes/v1.proto"

  defp domain_of(resource_body) do
    compile_domain(
      ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :list_notes, :read\n end),
      resource_body
    )
  end

  defp note(attributes, grpc \\ "", extra \\ "") do
    """
    #{grpc}

    attributes do
      uuid_primary_key :id, public?: true
      #{attributes}
    end

    actions do
      defaults [:read]
    end

    #{extra}
    """
  end

  defp strings(names),
    do: Enum.map_join(names, "\n", &"attribute #{inspect(&1)}, :string, public?: true")

  defp generate(domain, committed \\ nil) do
    previous = if committed, do: %{@file_path => committed}, else: %{}
    [{@file_path, text}] = AshGrpc.Proto.render([domain], previous: previous)
    text
  end

  defp message(domain, prefix, committed \\ nil) do
    previous = if committed, do: %{@file_path => committed}, else: %{}
    [package] = AshGrpc.Schema.build([domain], previous: previous)
    found = Enum.find(package.messages, &String.starts_with?(&1.name, prefix))
    %{fields: Enum.map(found.fields, &{&1.name, &1.number}), reserved: found.reserved}
  end

  defp names(message), do: Enum.map(message.fields, &elem(&1, 0))

  defp child_source(prefix) do
    """
    defmodule #{prefix}.Child do
      use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets,
        extensions: [AshGrpc.Resource], validate_domain_inclusion?: false

      attributes do
        uuid_primary_key :id, public?: true
        attribute :parent_id, :uuid, public?: true
      end

      actions do
        defaults [:read]
      end
    end
    """
  end

  describe "the default set" do
    test "GIVEN only the extension WHEN the message is built THEN it is attributes, calculations, aggregates, relationships, numbered 1..n" do
      prefix = "AshGrpc.Compiled.Default#{System.unique_integer([:positive])}"
      compile(child_source(prefix))

      resource = """
      attributes do
        uuid_primary_key :id, public?: true
        attribute :title, :string, public?: true
      end

      calculations do
        calculate :shout, :string, expr(title <> "!"), public?: true
      end

      aggregates do
        count :child_count, :children, public?: true
      end

      relationships do
        has_many :children, #{prefix}.Child, public?: true, destination_attribute: :parent_id
      end

      actions do
        defaults [:read]
      end
      """

      message = message(domain_of(resource), "Resource")

      assert message.fields ==
               [id: 1, title: 2, shout: 3, child_count: 4, children: 5]
    end

    test "GIVEN fields that cannot be sent WHEN only the extension is used THEN each is left out and the build succeeds" do
      plain = AshGrpc.TestSupport.Plain

      resource = """
      attributes do
        uuid_primary_key :id, public?: true
        attribute :title, :string, public?: true
        attribute :hidden, :string
        attribute :password, :string, public?: true, sensitive?: true
        attribute :blob, :term, public?: true
      end

      calculations do
        calculate :greet, :string, expr("hi " <> ^arg(:who)) do
          public? true
          argument :who, :string, allow_nil?: false
        end

        calculate :shout, :string, expr(title <> "!"), public?: true
      end

      relationships do
        has_one :plain, #{inspect(plain)}, public?: true, destination_attribute: :id
      end

      actions do
        defaults [:read]
      end
      """

      assert names(message(domain_of(resource), "Resource")) == [:id, :title, :shout]
    end

    test "GIVEN a grpc block with only other options WHEN the message is built THEN the public fields are still sent" do
      resource = note(strings([:title]), ~s(grpc do\n proto_message "Note"\n end))

      assert message(domain_of(resource), "Note").fields == [id: 1, title: 2]
    end

    test "GIVEN hide_fields WHEN the message is built THEN those fields are removed" do
      resource = note(strings([:title, :body]), "grpc do\n hide_fields [:body]\n end")

      assert names(message(domain_of(resource), "Resource")) == [:id, :title]
    end

    test "GIVEN hide_fields naming a field that is not public WHEN it compiles THEN the build stops" do
      resource =
        note(
          strings([:title]) <> "\nattribute :secret, :string",
          "grpc do\n hide_fields [:secret, :nope]\n end"
        )

      error = assert_raise DslError, fn -> domain_of(resource) end

      assert error.message =~ "hide_fields"
      assert error.message =~ "[:secret, :nope]"
    end

    test "GIVEN hide_fields together with fields WHEN it compiles THEN the build stops saying to use one" do
      resource =
        note(strings([:title]), "grpc do\n fields id: 1, title: 2\n hide_fields [:title]\n end")

      assert_raise DslError, ~r/hide_fields.*together with `fields`.*one or the other/s, fn ->
        domain_of(resource)
      end
    end

    test "GIVEN fields listing a sensitive field WHEN it compiles THEN the build still stops" do
      resource =
        note(
          "attribute :password, :string, public?: true, sensitive?: true",
          "grpc do\n fields id: 1, password: 2\n end"
        )

      assert_raise DslError, ~r/sensitive/, fn -> domain_of(resource) end
    end

    test "GIVEN a default-mode resource WHEN there is no proto_output THEN the build stops with the config hint" do
      domain = domain_of(note(strings([:title])))

      error = assert_raise DslError, fn -> AshGrpc.Schema.build([domain]) end

      assert error.message =~ ~s(config :ash_grpc, proto_output: "priv/protos")
    end

    test "GIVEN a resource with 100 public attributes WHEN the message is built THEN all 101 fields are numbered" do
      attributes = for n <- 1..100, do: :"f#{n}"
      message = message(domain_of(note(strings(attributes))), "Resource")

      assert length(message.fields) == 101
      assert List.last(message.fields) == {:f100, 101}
    end
  end

  describe "stable numbers" do
    test "GIVEN a committed file WHEN a public attribute is added THEN old numbers stay and the new one is appended" do
      first =
        generate(
          domain_of(note(strings([:title, :body]), ~s(grpc do\n proto_message "Note"\n end)))
        )

      grown =
        domain_of(note(strings([:slug, :title, :body]), ~s(grpc do\n proto_message "Note"\n end)))

      assert message(grown, "Note", first).fields == [id: 1, slug: 4, title: 2, body: 3]
    end

    test "GIVEN a committed file WHEN a field is made private THEN its number is reserved" do
      first =
        generate(
          domain_of(note(strings([:title, :body]), ~s(grpc do\n proto_message "Note"\n end)))
        )

      private =
        note(
          "attribute :title, :string, public?: true\nattribute :body, :string",
          ~s(grpc do\n proto_message "Note"\n end)
        )

      assert message(domain_of(private), "Note", first) ==
               %{fields: [id: 1, title: 2], reserved: [3]}
    end

    test "GIVEN a committed file WHEN a field is hidden THEN its number is reserved" do
      first =
        generate(
          domain_of(note(strings([:title, :body]), ~s(grpc do\n proto_message "Note"\n end)))
        )

      hidden =
        note(
          strings([:title, :body]),
          ~s(grpc do\n proto_message "Note"\n hide_fields [:body]\n end)
        )

      assert message(domain_of(hidden), "Note", first) ==
               %{fields: [id: 1, title: 2], reserved: [3]}
    end

    test "GIVEN default mode WHEN deprecated and reserved are set THEN they are rendered" do
      grpc = ~s(grpc do\n proto_message "Note"\n deprecated [:title]\n reserved [9]\n end)
      text = generate(domain_of(note(strings([:title]), grpc)))

      assert text =~ "optional string title = 2 [deprecated = true];"
      assert text =~ "reserved 9;"
    end

    test "GIVEN default mode WHEN deprecated names a field that is not sent THEN the build stops" do
      grpc = ~s(grpc do\n proto_message "Note"\n hide_fields [:title]\n deprecated [:title]\n end)

      assert_raise DslError, ~r/deprecated/, fn -> domain_of(note(strings([:title]), grpc)) end
    end

    test "GIVEN default mode WHEN deprecated names an unsendable field THEN the build stops when the message is built" do
      resource =
        note(
          "attribute :blob, :term, public?: true",
          ~s(grpc do\n proto_message "Note"\n deprecated [:blob]\n end)
        )

      domain = domain_of(resource)

      assert_raise DslError, ~r/deprecated.*\[:blob\]/, fn ->
        AshGrpc.Schema.build([domain], previous: %{})
      end
    end
  end

  describe "mixed with explicit resources" do
    test "GIVEN an explicit resource and a default one that reference each other WHEN the endpoint is built THEN both render" do
      prefix = "AshGrpc.Compiled.Mixed#{System.unique_integer([:positive])}"

      compile("""
      defmodule #{prefix}.Explicit do
        use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrpc.Resource], validate_domain_inclusion?: false

        grpc do
          fields id: 1, name: 2, other: 3
        end

        attributes do
          uuid_primary_key :id, public?: true
          attribute :name, :string, public?: true
        end

        relationships do
          has_one :other, #{prefix}.Automatic, public?: true, destination_attribute: :explicit_id
        end

        actions do
          defaults [:read]
        end
      end

      defmodule #{prefix}.Automatic do
        use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrpc.Resource], validate_domain_inclusion?: false

        attributes do
          uuid_primary_key :id, public?: true
          attribute :explicit_id, :uuid, public?: true
        end

        relationships do
          belongs_to :explicit, #{prefix}.Explicit, public?: true, define_attribute?: false, source_attribute: :explicit_id
        end

        actions do
          defaults [:read]
        end
      end
      """)

      domain =
        compile_domain("""
        package "mixed.v1"
        service "Mixed" do
          rpc #{prefix}.Explicit, :list_explicit, :read, load: [:other]
          rpc #{prefix}.Automatic, :list_automatic, :read, load: [:explicit]
        end
        """)

      [package] = AshGrpc.Schema.build([domain], previous: %{})
      by_name = Map.new(package.messages, &{&1.name, Enum.map(&1.fields, fn f -> f.name end)})

      assert by_name["Explicit"] == [:id, :name, :other]
      assert by_name["Automatic"] == [:id, :explicit_id, :explicit]
    end

    test "GIVEN a default-mode embedded resource WHEN it is a field type THEN it becomes a nested message of its public attributes" do
      embedded = "AshGrpc.Compiled.Address#{System.unique_integer([:positive])}"

      compile("""
      defmodule #{embedded} do
        use Ash.Resource, data_layer: :embedded, extensions: [AshGrpc.Resource]

        attributes do
          attribute :street, :string, public?: true
          attribute :private_note, :string
        end

        calculations do
          calculate :shout, :string, expr(street <> "!"), public?: true
        end
      end
      """)

      holder = note("attribute :address, #{embedded}, public?: true")
      domain = domain_of(holder)

      [package] = AshGrpc.Schema.build([domain], previous: %{})
      address = Enum.find(package.messages, &String.starts_with?(&1.name, "Address"))

      assert Enum.map(address.fields, &{&1.name, &1.number}) == [street: 1]
      assert names(message(domain, "Resource")) == [:id, :address]
    end
  end

  describe "over the wire" do
    setup do
      previous = Application.get_env(:ash_grpc, :proto_output)
      on_exit(fn -> restore_output(previous) end)

      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(shell) end)
    end

    @describetag :tmp_dir

    test "GIVEN a default-mode resource WHEN a record is created and listed THEN every public field comes back and a policy-hidden one is empty",
         %{tmp_dir: dir} do
      prefix = "AshGrpc.Compiled.Wire#{System.unique_integer([:positive])}"

      compile("""
      defmodule #{prefix}.Note do
        use Ash.Resource, domain: #{prefix}.Domain, data_layer: Ash.DataLayer.Ets,
          authorizers: [Ash.Policy.Authorizer], extensions: [AshGrpc.Resource]

        attributes do
          uuid_primary_key :id, public?: true
          attribute :title, :string, public?: true
          attribute :body, :string, public?: true
          attribute :views, :integer, public?: true, default: 3
          attribute :internal, :string
        end

        calculations do
          calculate :shout, :string, expr(title <> "!"), public?: true
        end

        actions do
          defaults [:read, create: [:title, :body]]
        end

        policies do
          policy always() do
            authorize_if always()
          end
        end

        field_policies do
          field_policy :body do
            forbid_if actor_attribute_equals(:name, "hush-body")
            authorize_if always()
          end

          field_policy :* do
            authorize_if always()
          end
        end
      end

      defmodule #{prefix}.Domain do
        use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

        resources do
          resource #{prefix}.Note
        end

        grpc do
          package "notes.v1"

          service "Notes" do
            rpc #{prefix}.Note, :create_note, :create, args: [title: 1, body: 2]
            rpc #{prefix}.Note, :list_notes, :read
          end
        end
      end
      """)

      endpoint = endpoint_with_output(Module.concat([prefix, "Domain"]), dir)
      Protos.run(["--endpoint", inspect(endpoint), "--output", dir])

      written = File.read!(Path.join(dir, @file_path))
      assert written =~ "optional string body = 3;"
      assert written =~ "optional string shout = 5;"

      channel = start(endpoint)
      stub = Module.concat([endpoint, "Notes", "V1", "Notes", "Stub"])

      create =
        struct!(Module.concat([endpoint, "Notes", "V1", "CreateNoteRequest"]),
          title: "hi",
          body: "text"
        )

      list = struct!(Module.concat([endpoint, "Notes", "V1", "ListNotesRequest"]), [])

      assert {:ok, %{result: created}} =
               stub.create_note(channel, create, metadata: signed_in("reader"))

      assert %{title: "hi", body: "text", views: 3} = created

      assert {:ok, %{result: [listed]}} =
               stub.list_notes(channel, list, metadata: signed_in("reader"))

      assert %{id: id, title: "hi", body: "text", views: 3, shout: "hi!"} = listed
      assert id == created.id

      assert {:ok, %{result: [hushed]}} =
               stub.list_notes(channel, list, metadata: signed_in("hush-body"))

      assert %{title: "hi", body: nil, shout: "hi!"} = hushed
    end

    test "GIVEN two default-mode resources that reference each other WHEN a call loads the relationship THEN the nested record is returned",
         %{tmp_dir: dir} do
      prefix = "AshGrpc.Compiled.Cycle#{System.unique_integer([:positive])}"

      compile("""
      defmodule #{prefix}.Author do
        use Ash.Resource, domain: #{prefix}.Domain, data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrpc.Resource]

        attributes do
          uuid_primary_key :id, public?: true
          attribute :name, :string, public?: true
        end

        relationships do
          has_many :books, #{prefix}.Book, public?: true
        end

        actions do
          defaults [:read, create: [:name]]
        end
      end

      defmodule #{prefix}.Book do
        use Ash.Resource, domain: #{prefix}.Domain, data_layer: Ash.DataLayer.Ets,
          extensions: [AshGrpc.Resource]

        attributes do
          uuid_primary_key :id, public?: true
          attribute :title, :string, public?: true
        end

        relationships do
          belongs_to :author, #{prefix}.Author, public?: true
        end

        actions do
          defaults [:read, create: [:title, :author_id]]
        end
      end

      defmodule #{prefix}.Domain do
        use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

        resources do
          resource #{prefix}.Author
          resource #{prefix}.Book
        end

        grpc do
          package "notes.v1"

          service "Notes" do
            rpc #{prefix}.Author, :list_authors, :read, load: [:books]
          end
        end
      end
      """)

      author = Module.concat([prefix, "Author"])
      book = Module.concat([prefix, "Book"])
      created = author |> Ash.Changeset.for_create(:create, %{name: "Ada"}) |> Ash.create!()

      book
      |> Ash.Changeset.for_create(:create, %{title: "Notes", author_id: created.id})
      |> Ash.create!()

      endpoint = endpoint_with_output(Module.concat([prefix, "Domain"]), dir)
      channel = start(endpoint)
      stub = Module.concat([endpoint, "Notes", "V1", "Notes", "Stub"])
      request = struct!(Module.concat([endpoint, "Notes", "V1", "ListAuthorsRequest"]), [])

      assert {:ok, %{result: [sent]}} =
               stub.list_authors(channel, request, metadata: signed_in("reader"))

      assert sent.name == "Ada"
      assert [%{title: "Notes", author_id: author_id}] = sent.books
      assert author_id == created.id
    end
  end

  defp endpoint_with_output(domain, dir) do
    Application.put_env(:ash_grpc, :proto_output, dir)
    compile_endpoint(domain)
  end

  defp restore_output(nil), do: Application.delete_env(:ash_grpc, :proto_output)
  defp restore_output(value), do: Application.put_env(:ash_grpc, :proto_output, value)
end
