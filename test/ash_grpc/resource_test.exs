defmodule AshGrpc.ResourceTest do
  use ExUnit.Case, async: true

  import AshGrpc.TestSupport.Compile

  alias AshGrpc.Resource.Info
  alias AshGrpc.TestSupport.Post
  alias Spark.Error.DslError

  @attributes """
  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
    attribute :tags, {:array, :string}, public?: true
    attribute :meta, :term, public?: true
    attribute :secret_note, :string
    attribute :password_hash, :string, public?: true, sensitive?: true
  end

  calculations do
    calculate :hidden_length, :integer, expr(string_length(title))
  end

  actions do
    defaults [:read]
  end
  """

  test "the grpc block is readable through Info" do
    assert Info.grpc_proto_message!(Post) == "Post"
    assert Keyword.fetch!(Info.grpc_fields!(Post), :title_length) == 12
    assert Info.exposed?(Post)
    refute Info.exposed?(AshGrpc.TestSupport.Plain)
  end

  test "a valid block compiles" do
    resource =
      compile_resource(
        ~s(grpc do\n proto_message "Ok"\n fields id: 1, title: 2\n end\n) <> @attributes
      )

    assert Info.grpc_fields!(resource) == [id: 1, title: 2]
  end

  test "the message is named after the last segment of the resource module" do
    resource = compile_resource(~s(grpc do\n fields id: 1, title: 2\n end\n) <> @attributes)

    assert Info.grpc_proto_message!(resource) ==
             resource |> Module.split() |> List.last()

    assert Info.exposed?(resource)
  end

  test "an explicit proto_message wins over the module name" do
    resource =
      compile_resource(
        ~s(grpc do\n proto_message "Article"\n fields id: 1, title: 2\n end\n) <> @attributes
      )

    assert Info.grpc_proto_message!(resource) == "Article"
  end

  test "a repeated field number does not compile" do
    assert_raise DslError, ~r/Field numbers repeat: \[1\]/, fn ->
      compile_resource(
        ~s(grpc do\n proto_message "Dup"\n fields id: 1, title: 1\n end\n) <> @attributes
      )
    end
  end

  test "a repeated field name does not compile" do
    assert_raise DslError, ~r/Field names repeat: \[:title\]/, fn ->
      compile_resource(
        ~s(grpc do\n proto_message "Dup"\n fields title: 1, title: 2\n end\n) <> @attributes
      )
    end
  end

  test "a zero field number does not compile" do
    assert_raise DslError, ~r/positive integers; not for \[:title\]/, fn ->
      compile_resource(
        ~s(grpc do\n proto_message "Zero"\n fields id: 1, title: 0\n end\n) <> @attributes
      )
    end
  end

  test "an unknown field does not compile" do
    assert_raise DslError,
                 ~r/names :subtitle, which is not an attribute, calculation, aggregate or relationship/,
                 fn ->
                   compile_resource(
                     ~s(grpc do\n proto_message "Unknown"\n fields id: 1, subtitle: 2\n end\n) <>
                       @attributes
                   )
                 end
  end

  test "reserved and deprecated are readable through Info" do
    assert Info.grpc_reserved!(Post) == [15, 16]
    assert Info.grpc_deprecated!(Post) == [:author_name]
  end

  test "a field using a reserved number does not compile" do
    assert_raise DslError, ~r/Field numbers \[2\] are reserved/, fn ->
      compile_resource(
        ~s(grpc do\n proto_message "R"\n fields id: 1, title: 2\n reserved [2]\n end\n) <>
          @attributes
      )
    end
  end

  test "a repeated reserved number does not compile" do
    assert_raise DslError, ~r/Reserved numbers repeat: \[7\]/, fn ->
      compile_resource(
        ~s(grpc do\n proto_message "R"\n fields id: 1\n reserved [7, 7]\n end\n) <> @attributes
      )
    end
  end

  test "deprecating a field that is not in fields does not compile" do
    assert_raise DslError, ~r/`deprecated` names \[:title\]/, fn ->
      compile_resource(
        ~s(grpc do\n proto_message "R"\n fields id: 1\n deprecated [:title]\n end\n) <>
          @attributes
      )
    end
  end

  test "a valid reserved and deprecated block compiles" do
    resource =
      compile_resource(
        ~s(grpc do\n proto_message "R"\n fields id: 1, title: 2\n reserved [3]\n deprecated [:title]\n end\n) <>
          @attributes
      )

    assert Info.grpc_reserved!(resource) == [3]
    assert Info.grpc_deprecated!(resource) == [:title]
  end

  test "a term field does not compile and names the field" do
    assert_raise DslError,
                 ~r/Field :meta has type Ash.Type.Term, which has no protobuf mapping: it can hold any term/,
                 fn ->
                   compile_resource(
                     ~s(grpc do\n proto_message "Meta"\n fields id: 1, meta: 2\n end\n) <>
                       @attributes
                   )
                 end
  end

  test "a private attribute does not compile and names the field" do
    assert_raise DslError, ~r/Field :secret_note is not public/, fn ->
      compile_resource(
        ~s(grpc do\n proto_message "Private"\n fields id: 1, secret_note: 2\n end\n) <>
          @attributes
      )
    end
  end

  test "a private calculation does not compile and names the field" do
    assert_raise DslError, ~r/Field :hidden_length is not public/, fn ->
      compile_resource(
        ~s(grpc do\n proto_message "Private"\n fields id: 1, hidden_length: 2\n end\n) <>
          @attributes
      )
    end
  end

  test "a sensitive attribute does not compile and names the field" do
    assert_raise DslError, ~r/Field :password_hash is sensitive/, fn ->
      compile_resource(
        ~s(grpc do\n proto_message "Sensitive"\n fields id: 1, password_hash: 2\n end\n) <>
          @attributes
      )
    end
  end

  describe "a calculation with arguments" do
    defp with_calculation(argument_opts) do
      ~s(grpc do\n proto_message "Calc"\n fields id: 1, scaled: 2\n end\n) <>
        """
        attributes do
          uuid_primary_key :id, public?: true
          attribute :views, :integer, public?: true
        end

        calculations do
          calculate :scaled, :integer, expr(views * ^arg(:factor)) do
            public? true
            argument :factor, :integer do
              #{argument_opts}
            end
          end
        end

        actions do
          defaults [:read]
        end
        """
    end

    test "a required argument does not compile and names the calculation and argument" do
      assert_raise DslError, ~r/:scaled.*:factor/s, fn ->
        compile_resource(with_calculation("allow_nil? false"))
      end
    end

    test "an argument with a default compiles" do
      assert compile_resource(with_calculation("allow_nil? false\n default 2"))
    end

    test "an argument that allows nil compiles" do
      assert compile_resource(with_calculation("allow_nil? true"))
    end
  end
end
