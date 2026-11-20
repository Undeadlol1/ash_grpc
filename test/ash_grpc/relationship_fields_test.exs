defmodule AshGrpc.RelationshipFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.Proto.Compatibility
  alias AshGrpc.TestSupport.Library.Author
  alias AshGrpc.TestSupport.Library.Book
  alias AshGrpc.TestSupport.Library.BookTag
  alias AshGrpc.TestSupport.Library.Profile
  alias AshGrpc.TestSupport.Library.Tag
  alias AshGrpc.TestSupport.LibraryEndpoint
  alias AshGrpc.TestSupport.LibraryEndpoint.Library.V1
  alias AshGrpc.TestSupport.LibraryEndpoint.Library.V1.Library.Stub
  alias AshGrpc.TestSupport.Protoc
  alias Spark.Error.DslError

  defp create!(resource, params),
    do: resource |> Ash.Changeset.for_create(:create, params) |> Ash.create!(authorize?: false)

  defp author!(name), do: create!(Author, %{name: name})
  defp book!(author, title), do: create!(Book, %{title: title, author_id: author.id})

  defp tag!(book, label) do
    tag = create!(Tag, %{label: label})
    create!(BookTag, %{book_id: book.id, tag_id: tag.id})
    tag
  end

  defp by_name(authors), do: Map.new(authors, &{&1.name, &1})

  describe "proto" do
    test "a relationship is a message field, repeated for a to-many one, and messages may recurse" do
      [{_path, text}] = AshGrpc.Proto.render(LibraryEndpoint)

      assert text =~ "  repeated Book books = 5;\n  Profile profile = 6;\n}"
      assert text =~ "  Author author = 3;\n  repeated Tag tags = 4;\n}"

      assert text =~
               "message Tag {\n  string id = 1;\n  optional string label = 2;\n  repeated Book books = 3;\n}"
    end

    @tag :protoc
    @tag :tmp_dir
    test "protoc accepts the recursive file", %{tmp_dir: tmp_dir} do
      [{path, text}] = AshGrpc.Proto.render(LibraryEndpoint)
      File.mkdir_p!(Path.join(tmp_dir, Path.dirname(path)))
      File.write!(Path.join(tmp_dir, path), text)

      assert {_output, 0} =
               System.cmd(
                 Protoc.path(),
                 ["--proto_path=#{tmp_dir}", "--descriptor_set_out=/dev/null", path],
                 stderr_to_stdout: true
               )
    end

    test "the compatibility checker reads relationship fields like any message field" do
      [{_path, text}] = AshGrpc.Proto.render(LibraryEndpoint)

      assert Compatibility.check(text, text) == :ok

      dropped = String.replace(text, "  repeated Book books = 5;\n", "")
      assert [change] = Compatibility.check(text, dropped)
      assert change =~ "field 5"

      retyped = String.replace(text, "  Profile profile = 6;", "  repeated Profile profile = 6;")
      assert [_change] = Compatibility.check(text, retyped)
    end
  end

  describe "compile errors" do
    test "a private relationship is rejected" do
      assert_raise DslError, ~r/Field :entries is not public/, fn ->
        compile_resource("""
        grpc do
          fields id: 1, entries: 2
        end

        attributes do
          uuid_primary_key :id, public?: true
        end

        relationships do
          has_many :entries, AshGrpc.TestSupport.Entry, destination_attribute: :tally_id
        end
        """)
      end
    end

    test "a destination without a grpc block names both resources" do
      plain = AshGrpc.TestSupport.Plain

      domain =
        compile_domain(
          ~s(package "orphans.v1"\nservice "Orphans" do\n rpc INLINE, :list_orphans, :read, sort: false, filter: false, page: false\n end),
          """
          grpc do
            fields id: 1, plain: 2
          end

          attributes do
            uuid_primary_key :id, public?: true
          end

          relationships do
            has_one :plain, #{inspect(plain)}, public?: true, destination_attribute: :id
          end

          actions do
            defaults [:read]
          end
          """
        )

      error = assert_raise DslError, fn -> compile_endpoint(domain) end
      assert error.message =~ ":plain"
      assert error.message =~ inspect(plain)
      assert error.message =~ "does not use `AshGrpc.Resource`"
    end

    test "load names a relationship that is not a relationship" do
      assert_raise DslError, ~r/`load` names :title, which is not a relationship/, fn ->
        compile_library_domain("load: [:title]")
      end
    end

    test "load names a relationship that is not a field of the message" do
      assert_raise DslError,
                   ~r/`load` names the relationship :tags, which is not in the grpc `fields`/,
                   fn ->
                     compile_library_domain(
                       "load: [author: [:books], tags: []]",
                       "fields id: 1, title: 2, author: 3"
                     )
                   end
    end

    test "load is checked at every depth" do
      assert_raise DslError,
                   ~r/`load` names :nope, which is not a relationship of .*Author/,
                   fn ->
                     compile_library_domain("load: [author: [:nope]]")
                   end
    end

    test "load needs an action that returns records" do
      assert_raise DslError, ~r/`load` needs an action that returns/, fn ->
        compile_library_domain("load: [:author]", nil, ":ping")
      end
    end
  end

  defp compile_library_domain(load_option, fields \\ nil, action \\ ":read") do
    fields = fields || "fields id: 1, title: 2, author: 3, tags: 4"

    domain =
      compile_domain(
        ~s(package "loads.v1"\nservice "Loads" do\n rpc INLINE, :list_things, #{action}, #{load_option}\n end),
        """
        grpc do
          #{fields}
        end

        attributes do
          uuid_primary_key :id, public?: true
          attribute :title, :string, public?: true
        end

        relationships do
          belongs_to :author, AshGrpc.TestSupport.Library.Author, public?: true
          belongs_to :tags, AshGrpc.TestSupport.Library.Tag, public?: true, define_attribute?: false, source_attribute: :id
        end

        actions do
          defaults [:read]
          action :ping, :string do
            run fn _input, _context -> {:ok, "pong"} end
          end
        end
        """
      )

    compile_endpoint(domain)
  end

  describe "over a real connection" do
    setup do
      %{channel: start(LibraryEndpoint), metadata: signed_in("reader")}
    end

    defp authors(channel, metadata, rpc, request \\ nil) do
      request = request || struct(Module.concat(V1, Macro.camelize("#{rpc}_request")))
      {:ok, %{result: authors}} = apply(Stub, rpc, [channel, request, [metadata: metadata]])
      by_name(authors)
    end

    test "a relationship that was not asked for is absent", %{
      channel: channel,
      metadata: metadata
    } do
      author = author!("plain#{System.unique_integer([:positive])}")
      book!(author, "unseen")

      %{} = found = authors(channel, metadata, :list_authors)
      assert %{books: [], profile: nil} = found[author.name]
    end

    test "has_many sends the loaded records with their own calculations and aggregates",
         %{channel: channel, metadata: metadata} do
      author = author!("many#{System.unique_integer([:positive])}")
      book!(author, "first")
      book!(author, "second")

      sent = authors(channel, metadata, :list_authors_with_books)[author.name]

      assert sent.book_count == 2
      assert sent.name_length == String.length(author.name)
      assert sent.books |> Enum.map(& &1.title) |> Enum.sort() == ["first", "second"]
      assert Enum.all?(sent.books, &(&1.author == nil))
    end

    test "belongs_to and many_to_many are loaded by the book list", %{
      channel: channel,
      metadata: metadata
    } do
      author = author!("owner#{System.unique_integer([:positive])}")
      book = book!(author, "tagged#{System.unique_integer([:positive])}")
      tag!(book, "red")
      tag!(book, "blue")

      {:ok, %{result: books}} =
        Stub.list_books(channel, %V1.ListBooksRequest{}, metadata: metadata)

      sent = Enum.find(books, &(&1.id == book.id))

      assert sent.author.name == author.name
      assert sent.author.books == []
      assert sent.tags |> Enum.map(& &1.label) |> Enum.sort() == ["blue", "red"]
      assert Enum.all?(sent.tags, &(&1.books == []))
    end

    test "has_one is loaded for a caller who may read it", %{channel: channel} do
      author = author!("single#{System.unique_integer([:positive])}")
      create!(Profile, %{bio: "likes ducks", author_id: author.id})
      admin = signed_in("boss", %{"x-role" => "admin"})

      assert authors(channel, admin, :list_authors_with_profile)[author.name].profile.bio ==
               "likes ducks"
    end

    test "a caller who may not read the related resource gets the parent without it", %{
      channel: channel,
      metadata: metadata
    } do
      author = author!("guarded#{System.unique_integer([:positive])}")
      create!(Profile, %{bio: "secret", author_id: author.id})

      sent = authors(channel, metadata, :list_authors_with_profile)[author.name]

      assert sent.name == author.name
      assert sent.profile == nil
    end

    test "nested loads go as deep as load says and no deeper", %{channel: channel} do
      author = author!("deep#{System.unique_integer([:positive])}")
      book = book!(author, "layered")
      tag!(book, "green")
      create!(Profile, %{bio: "deep bio", author_id: author.id})
      admin = signed_in("boss", %{"x-role" => "admin"})

      sent = authors(channel, admin, :list_authors_deep)[author.name]
      [sent_book] = sent.books

      assert sent_book.author.name == author.name
      assert sent_book.author.books == []
      assert Enum.map(sent_book.tags, & &1.label) == ["green"]
      assert sent_book.tags |> hd() |> Map.fetch!(:books) == []
      assert sent.profile.author.name == author.name
      assert sent.profile.author.profile == nil
    end

    test "a create response carries the relationships it loads", %{
      channel: channel,
      metadata: metadata
    } do
      {:ok, %{result: created}} =
        Stub.create_author(channel, %V1.CreateAuthorRequest{name: "fresh"}, metadata: metadata)

      assert created.books == []
    end

    test "a create with a manage_relationship argument sends the managed records", %{
      channel: channel,
      metadata: metadata
    } do
      books = [%{"title" => "one"}, %{"title" => "two"}]

      request = %V1.CreateAuthorWithBooksRequest{
        name: "prolific",
        books: Enum.map(books, &struct_of/1)
      }

      {:ok, %{result: created}} =
        Stub.create_author_with_books(channel, request, metadata: metadata)

      assert created.books |> Enum.map(& &1.title) |> Enum.sort() == ["one", "two"]
      assert created.book_count == 2
    end

    test "get, update, destroy and generic actions load too", %{
      channel: channel,
      metadata: metadata
    } do
      author = author!("keyed#{System.unique_integer([:positive])}")
      book = book!(author, "old")

      {:ok, %{result: got}} =
        Stub.get_book(channel, %V1.GetBookRequest{id: book.id}, metadata: metadata)

      assert got.author.name == author.name

      {:ok, %{result: updated}} =
        Stub.update_book(channel, %V1.UpdateBookRequest{id: book.id, title: "new"},
          metadata: metadata
        )

      assert {updated.title, updated.author.name} == {"new", author.name}

      {:ok, %{result: favourite}} =
        Stub.favourite_book(channel, %V1.FavouriteBookRequest{}, metadata: metadata)

      assert favourite.author.name

      {:ok, %{result: destroyed}} =
        Stub.destroy_book(channel, %V1.DestroyBookRequest{id: book.id}, metadata: metadata)

      assert destroyed.author.name == author.name
    end

    test "a subscription's snapshot and changes carry the loaded relationship", %{
      channel: channel,
      metadata: metadata
    } do
      author = author!("watched#{System.unique_integer([:positive])}")
      existing = book!(author, "snapshot")
      test = self()

      spawn_link(fn ->
        {:ok, replies} = Stub.watch_books(channel, %V1.WatchBooksRequest{}, metadata: metadata)
        Enum.each(replies, fn {:ok, reply} -> send(test, {:reply, reply}) end)
      end)

      snapshot = snapshot_until_synced([])
      assert snapshot[existing.id].author.name == author.name

      changed = book!(author, "live")
      assert_receive {:reply, %{result: %{id: changed_id} = change}}, 2_000
      assert changed_id == changed.id
      assert change.author.name == author.name
    end
  end

  defp snapshot_until_synced(books) do
    assert_receive {:reply, reply}, 2_000

    if reply.synced,
      do: Map.new(books, &{&1.id, &1}),
      else: snapshot_until_synced([reply.result | books])
  end

  defp struct_of(map), do: AshGrpc.Types.encode(:struct, map)
end
