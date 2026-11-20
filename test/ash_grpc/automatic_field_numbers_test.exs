defmodule AshGrpc.AutomaticFieldNumbersTest do
  use ExUnit.Case, async: true

  import AshGrpc.TestSupport.Compile

  alias Spark.Error.DslError

  @file_path "notes/v1.proto"

  defp domain(fields, opts \\ []) do
    message = Keyword.get(opts, :message, "Note")
    attributes = Keyword.get(opts, :attributes, [:title, :body, :slug, :summary])

    resource = """
    grpc do
      proto_message "#{message}"
      #{fields}
    end

    attributes do
      uuid_primary_key :id, public?: true
      #{Enum.map_join(attributes, "\n", &"attribute #{inspect(&1)}, :string, public?: true")}
    end

    actions do
      defaults [:read]
    end
    """

    compile_domain(
      ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :list_notes, :read, sort: false, filter: false, page: false\n end),
      resource
    )
  end

  defp generate(domain, committed \\ nil) do
    previous = if committed, do: %{@file_path => committed}, else: %{}
    [{@file_path, text}] = AshGrpc.Proto.render([domain], previous: previous)
    text
  end

  defp message(domain, committed, name \\ "Note") do
    previous = if committed, do: %{@file_path => committed}, else: %{}
    [package] = AshGrpc.Schema.build([domain], previous: previous)
    found = Enum.find(package.messages, &(&1.name == name))
    %{numbers: Map.new(found.fields, &{&1.name, &1.number}), reserved: found.reserved}
  end

  defp numbers(domain, committed \\ nil), do: message(domain, committed).numbers

  test "GIVEN no committed file WHEN fields have no numbers THEN they are numbered 1..n in declaration order" do
    assert numbers(domain("fields [:id, :title, :body]")) == %{id: 1, title: 2, body: 3}
  end

  test "GIVEN a committed file WHEN a field is appended THEN old numbers stay and the new one is max + 1" do
    committed = generate(domain("fields [:id, :title, :body]"))

    assert numbers(domain("fields [:id, :title, :body, :slug]"), committed) ==
             %{id: 1, title: 2, body: 3, slug: 4}
  end

  test "GIVEN a committed file WHEN a field is inserted in the middle and the list reordered THEN no existing number changes" do
    committed = generate(domain("fields [:id, :title, :body]"))

    assert numbers(domain("fields [:body, :slug, :id, :title]"), committed) ==
             %{id: 1, title: 2, body: 3, slug: 4}
  end

  test "GIVEN automatic numbers WHEN a field is removed THEN its number is reserved, never reused and stays reserved" do
    first = generate(domain("fields [:id, :title, :body]"))
    after_removal = generate(domain("fields [:id, :title]"), first)
    after_addition = generate(domain("fields [:id, :title, :slug]"), after_removal)
    regenerated = generate(domain("fields [:id, :title, :slug]"), after_addition)

    assert message(domain("fields [:id, :title]"), first).reserved == [3]

    assert message(domain("fields [:id, :title, :slug]"), after_removal) ==
             %{numbers: %{id: 1, title: 2, slug: 4}, reserved: [3]}

    assert regenerated == after_addition
    assert regenerated =~ "reserved 3;"
  end

  test "GIVEN a removed field WHEN it is added back under the same name THEN it gets a new number and the old stays reserved" do
    first = generate(domain("fields [:id, :title, :body]"))
    after_removal = generate(domain("fields [:id, :title]"), first)

    assert message(domain("fields [:id, :title, :body]"), after_removal) ==
             %{numbers: %{id: 1, title: 2, body: 4}, reserved: [3]}
  end

  test "GIVEN no committed file WHEN explicit and automatic numbers mix THEN automatic numbers fill from 1 around the explicit ones" do
    assert numbers(domain("fields [:id, :body, title: 1]")) == %{id: 2, body: 3, title: 1}
    assert numbers(domain("fields [:id, :body, title: 7]")) == %{id: 1, body: 2, title: 7}
  end

  test "GIVEN a committed file WHEN an explicit number is higher than everything THEN the next automatic number is above it" do
    committed = generate(domain("fields [:id, :title]"))

    assert numbers(domain("fields [:id, :title, :body, slug: 10]"), committed) ==
             %{id: 1, title: 2, body: 11, slug: 10}
  end

  test "GIVEN a committed field WHEN another field is pinned to its number while it stays un-numbered THEN the build stops" do
    committed = generate(domain("fields [:id, :title, :body]"))

    error =
      assert_raise DslError, fn ->
        message(domain("fields [:id, :title, body: 2]"), committed)
      end

    assert error.message =~ "Note"
    assert error.message =~ ":body"
    assert error.message =~ "title"
  end

  test "GIVEN a committed file WHEN a field is pinned to a number the file reserves THEN the build stops" do
    first = generate(domain("fields [:id, :title, :body]"))
    after_removal = generate(domain("fields [:id, :title]"), first)

    assert_raise DslError, ~r/Note.*\[3\] are reserved/, fn ->
      message(domain("fields [:id, :title, slug: 3]"), after_removal)
    end
  end

  test "GIVEN a renamed field WHEN the new name is pinned to the old number THEN the number is kept and not reserved" do
    committed = generate(domain("fields [:id, :title, :body]"))

    assert message(domain("fields [:id, :body, slug: 2]"), committed) ==
             %{numbers: %{id: 1, slug: 2, body: 3}, reserved: []}
  end

  test "GIVEN an all-explicit resource WHEN a committed field is gone THEN nothing is reserved automatically" do
    committed = generate(domain("fields id: 1, title: 2, body: 3"))

    assert message(domain("fields id: 1, title: 2"), committed).reserved == []
  end

  test "GIVEN a committed file without this message WHEN the resource is new THEN it is numbered 1..n" do
    committed = generate(domain("fields [:id, :slug, :summary, :title]", message: "Memo"))

    assert numbers(domain("fields [:id, :title]"), committed) == %{id: 1, title: 2}
  end

  test "GIVEN one package WHEN an automatic embedded message sits in an explicit resource THEN each keeps its own numbering" do
    committed = generate_homes(home_domain("[:city]"))

    [package] =
      AshGrpc.Schema.build([home_domain("[:street, :city]")],
        previous: %{"homes/v1.proto" => committed}
      )

    by_name =
      Map.new(package.messages, &{&1.name, Map.new(&1.fields, fn f -> {f.name, f.number} end)})

    assert by_name["Address"] == %{city: 1, street: 2}
    assert by_name["Home"] == %{id: 5, address: 9}
  end

  test "GIVEN an unparseable committed file WHEN numbers are needed THEN the build stops naming the file" do
    assert_raise DslError, ~r/notes\/v1.proto.*cannot be read/s, fn ->
      numbers(domain("fields [:id, :title]"), "syntax = \"proto3\";\nnonsense\n")
    end
  end

  test "GIVEN a committed message using one number twice WHEN numbers are needed THEN the build stops naming it" do
    committed = "message Note {\n  string id = 1;\n  optional string title = 1;\n}\n"

    error = assert_raise DslError, fn -> numbers(domain("fields [:id, :title]"), committed) end

    assert error.message =~ "Note"
    assert error.message =~ "number 1"
  end

  test "GIVEN no proto_output WHEN a field has no number THEN the build stops with the config hint" do
    error =
      assert_raise DslError, fn -> AshGrpc.Schema.build([domain("fields [:id, :title]")]) end

    assert error.message =~ ~s(config :ash_grpc, proto_output: "priv/protos")
    assert error.message =~ "same between builds"
  end

  test "GIVEN no proto_output WHEN every field is numbered THEN the build works as before" do
    assert [%{messages: [%{name: "Note"}]}] =
             AshGrpc.Schema.build([domain("fields id: 1, title: 2")])
  end

  test "GIVEN a committed number just below 19000 WHEN a field is added THEN it skips to 20000" do
    committed = generate(domain("fields id: 18999, title: 2"))

    assert numbers(domain("fields [:id, :title, :body]"), committed) ==
             %{id: 18_999, title: 2, body: 20_000}
  end

  test "GIVEN the last number protobuf allows is taken WHEN a field is added THEN the build stops" do
    committed = generate(domain("fields id: 536_870_911, title: 2"))

    assert_raise DslError, ~r/Note: no free field number left for :body/, fn ->
      numbers(domain("fields [:id, :title, :body]"), committed)
    end
  end

  test "GIVEN 200 automatic fields WHEN one is removed and two are added THEN only the new ones get numbers" do
    wide = for n <- 1..200, do: :"f#{n}"
    attributes = wide ++ [:g1, :g2]
    first = generate(domain("fields #{inspect(wide, limit: :infinity)}", attributes: attributes))
    changed = List.delete(wide, :f100) ++ [:g1, :g2]

    result =
      message(
        domain("fields #{inspect(changed, limit: :infinity)}", attributes: attributes),
        first
      )

    assert result.reserved == [100]
    assert result.numbers[:f1] == 1
    assert result.numbers[:f200] == 200
    assert result.numbers[:g1] == 201
    assert result.numbers[:g2] == 202
  end

  test "GIVEN a repeated name in an un-numbered list WHEN it compiles THEN it is refused" do
    assert_raise DslError, ~r/Field names repeat: \[:title\]/, fn ->
      domain("fields [:id, :title, :title]")
    end
  end

  test "GIVEN an unknown name in an un-numbered list WHEN it compiles THEN it is refused" do
    assert_raise DslError, ~r/names :nope, which is not an attribute/, fn ->
      domain("fields [:id, :nope]")
    end
  end

  defp generate_homes(domain) do
    [{"homes/v1.proto", text}] = AshGrpc.Proto.render([domain], previous: %{})
    text
  end

  defp home_domain(address_fields) do
    address = "AshGrpc.Compiled.Address#{System.unique_integer([:positive])}"

    compile("""
    defmodule #{address} do
      use Ash.Resource, data_layer: :embedded, extensions: [AshGrpc.Resource]

      grpc do
        proto_message "Address"
        fields #{address_fields}
      end

      attributes do
        attribute :street, :string, public?: true
        attribute :city, :string, public?: true
      end
    end
    """)

    home = """
    grpc do
      proto_message "Home"
      fields id: 5, address: 9
    end

    attributes do
      uuid_primary_key :id, public?: true
      attribute :address, #{address}, public?: true
    end

    actions do
      defaults [:read]
    end
    """

    compile_domain(
      ~s(package "homes.v1"\nservice "Homes" do\n rpc INLINE, :list_homes, :read, sort: false, filter: false, page: false\n end),
      home
    )
  end
end
