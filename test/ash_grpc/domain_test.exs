defmodule AshGrpc.DomainTest do
  use ExUnit.Case, async: true

  import AshGrpc.TestSupport.Compile

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
    defaults [:read, :destroy, create: [:title], update: [:title]]

    action :shout, :string do
      run fn _input, _context -> {:ok, "hi"} end
    end

    action :ping do
      run fn _input, _context -> :ok end
    end

    read :paged_required do
      pagination offset?: true, required?: true, default_limit: 5
    end

    read :paged_optional do
      pagination offset?: true, required?: false
    end

    action :clearable, :struct do
      constraints instance_of: __MODULE__
      argument :clear_fields, :string
      run fn _input, _context -> {:ok, nil} end
    end

    action :tag, :struct do
      constraints instance_of: __MODULE__
      argument :meta, :term
      run fn _input, _context -> {:ok, nil} end
    end
  end
  """

  defp assert_invalid(grpc_body, message) do
    domain = compile_domain(~s(package "notes.v1"\n) <> grpc_body, @resource)
    assert_raise DslError, message, fn -> AshGrpc.Schema.build([domain]) end
  end

  test "a valid domain builds its package" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :list_notes, :read, sort: false, filter: false, page: false\n end),
        @resource
      )

    assert [%{package: "notes.v1", services: [%{name: "Notes"}]}] = AshGrpc.Schema.build([domain])
  end

  test "an unknown action is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :find, :find\n end),
      ~r/has no action :find/
    )
  end

  test "a resource without a grpc block is rejected" do
    domain =
      compile_domain(
        ~s(package "plain.v1"\nservice "Plain" do\n rpc AshGrpc.TestSupport.Plain, :list, :read, sort: false, filter: false, page: false\n end)
      )

    assert_raise DslError,
                 ~r/AshGrpc.TestSupport.Plain, which is not an Ash resource with a `grpc` block/,
                 fn ->
                   AshGrpc.Schema.build([domain])
                 end
  end

  test "a repeated rpc name is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :list, :read, sort: false, filter: false, page: false\n rpc INLINE, :list, :read, sort: false, filter: false, page: false\n end),
      ~r/Rpc names repeat: \[:list\]/
    )
  end

  test "a repeated arg number is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :edit, :update, args: [id: 1, title: 1]\n end),
      ~r/Field numbers repeat: \[1\]/
    )
  end

  test "a repeated arg name is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :edit, :update, args: [id: 1, title: 2, title: 3]\n end),
      ~r/Field names repeat: \[:title\]/
    )
  end

  test "an arg using a reserved number is rejected and names the rpc" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :edit, :update, args: [id: 1, title: 2], reserved: [2]\n end),
      ~r/rpc :edit: Field numbers \[2\] are reserved/
    )
  end

  test "a repeated reserved number on an rpc is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :add, :create, args: [title: 1], reserved: [4, 4]\n end),
      ~r/rpc :add: Reserved numbers repeat: \[4\]/
    )
  end

  test "clear_fields using an arg number is rejected and names the rpc" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :edit, :update, args: [id: 1, title: 2], clear_fields: 2\n end),
      ~r/rpc :edit: `clear_fields` uses number 2, which an arg already has/
    )
  end

  test "clear_fields using a reserved number is rejected and names the rpc" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :edit, :update, args: [id: 1, title: 2], reserved: [3], clear_fields: 3\n end),
      ~r/rpc :edit: Field numbers \[3\] are reserved/
    )
  end

  test "clear_fields next to an arg of that name is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :mark, :clearable, args: [clear_fields: 1], clear_fields: 2\n end),
      ~r/rpc :mark: an arg is already named :clear_fields/
    )
  end

  test "clear_fields adds a repeated string field to the request" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :edit, :update, args: [id: 1, title: 2], clear_fields: 3\n end),
        @resource
      )

    assert [{_path, text}] = AshGrpc.Proto.render([domain])
    assert text =~ "  repeated string clear_fields = 3;"
  end

  test "a reserved number and a deprecated flag on an rpc are accepted" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :add, :create, args: [title: 2], reserved: [1], deprecated: true\n end),
        @resource
      )

    assert [%{services: [%{rpcs: [rpc]}]}] = AshGrpc.Schema.build([domain])
    assert rpc.deprecated?
    assert rpc.request.reserved == [1]
  end

  test "an unknown arg is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :add, :create, args: [subtitle: 1]\n end),
      ~r/`args` names :subtitle, which is not an argument, accepted attribute or primary key/
    )
  end

  test "an update without its primary key is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :edit, :update, args: [title: 1]\n end),
      ~r/the update action needs the primary key in `args`; missing \[:id\]/
    )
  end

  test "a destroy whose args leave out the primary key is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :remove, :destroy, args: []\n end),
      ~r/the destroy action needs the primary key in `args`; missing \[:id\]/
    )
  end

  describe "the read action that finds the record" do
    @two_reads String.replace(
                 @resource,
                 "defaults [:read, :destroy, create: [:title], update: [:title]]",
                 "defaults [:destroy, create: [:title], update: [:title]]\n read :first\n read :second"
               )

    defp assert_invalid_two_reads(grpc_body, message) do
      domain = compile_domain(~s(package "notes.v1"\n) <> grpc_body, @two_reads)
      assert_raise DslError, message, fn -> AshGrpc.Schema.build([domain]) end
    end

    test "an update without a primary read action is rejected naming the rpc and resource" do
      assert_invalid_two_reads(
        ~s(service "Notes" do\n rpc INLINE, :edit, :update, args: [id: 1, title: 2]\n end),
        ~r/rpc :edit: the update action finds its record.*has no primary read action/s
      )
    end

    test "a destroy without a primary read action is rejected" do
      assert_invalid_two_reads(
        ~s(service "Notes" do\n rpc INLINE, :remove, :destroy, args: [id: 1]\n end),
        ~r/rpc :remove: the destroy action finds its record.*has no primary read action/s
      )
    end

    test "read_action makes up for a missing primary read action" do
      domain =
        compile_domain(
          ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :edit, :update, args: [id: 1, title: 2], read_action: :second, clear_fields: false\n end),
          @two_reads
        )

      assert [%{services: [%{rpcs: [%{read_action: :second}]}]}] = AshGrpc.Schema.build([domain])
    end

    test "read_action must name a read action" do
      assert_invalid(
        ~s(service "Notes" do\n rpc INLINE, :edit, :update, args: [id: 1, title: 2], read_action: :destroy\n end),
        ~r/rpc :edit: `read_action` :destroy is not a read action/
      )
    end

    test "read_action is refused on other action types" do
      assert_invalid(
        ~s(service "Notes" do\n rpc INLINE, :add, :create, args: [title: 1], read_action: :read\n end),
        ~r/rpc :add: `read_action` only applies to an update or destroy/
      )
    end
  end

  test "a generic action that does not return the resource is accepted" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :shout, :shout\n end),
        @resource
      )

    assert [%{package: "notes.v1"}] = AshGrpc.Schema.build([domain])
  end

  test "a generic action with no return type is accepted" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :ping_it, :ping\n end),
        @resource
      )

    assert [%{package: "notes.v1"}] = AshGrpc.Schema.build([domain])
  end

  test "a read with required pagination is rejected" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :page, :paged_required, sort: false, filter: false, page: false\n end),
      ~r/rpc :page: read action :paged_required requires pagination/
    )
  end

  test "a read with optional pagination is accepted" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :page, :paged_optional\n end),
        @resource
      )

    assert [%{package: "notes.v1"}] = AshGrpc.Schema.build([domain], previous: %{})
  end

  test "an rpc whose request message is named like a resource message is rejected" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :note, :read, sort: false, filter: false, page: false\n end),
        String.replace(@resource, ~s(proto_message "Note"), ~s(proto_message "NoteRequest"))
      )

    assert_raise DslError,
                 ~r/Message name "NoteRequest" is defined more than once.*rpc :note/,
                 fn ->
                   AshGrpc.Schema.build([domain])
                 end
  end

  test "an rpc whose response message is named like a resource message is rejected" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :note, :read, sort: false, filter: false, page: false\n end),
        String.replace(@resource, ~s(proto_message "Note"), ~s(proto_message "NoteResponse"))
      )

    assert_raise DslError, ~r/Message name "NoteResponse" is defined more than once/, fn ->
      AshGrpc.Schema.build([domain])
    end
  end

  test "two resources whose modules end alike clash on the default message name" do
    [first, second] =
      for prefix <- ["First", "Second"] do
        name = "AshGrpc.Compiled.#{prefix}#{System.unique_integer([:positive])}.Memo"
        compile(resource_source(name, String.replace(@resource, ~s(proto_message "Note"\n), "")))
        Module.concat([name])
      end

    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc #{inspect(first)}, :a, :read, sort: false, filter: false, page: false\n rpc #{inspect(second)}, :b, :read, sort: false, filter: false, page: false\n end)
      )

    assert_raise DslError, ~r/Message name "Memo" is defined more than once/, fn ->
      AshGrpc.Schema.build([domain])
    end
  end

  test "an argument with no protobuf mapping is rejected and named" do
    assert_invalid(
      ~s(service "Notes" do\n rpc INLINE, :tag, :tag, args: [meta: 1]\n end),
      ~r/Field :meta has type Ash.Type.Term, which has no protobuf mapping/
    )
  end

  test "two resources with one message name in a package are rejected" do
    first = compile_resource(@resource)
    second = compile_resource(@resource)

    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc #{inspect(first)}, :a, :read, sort: false, filter: false, page: false\n rpc #{inspect(second)}, :b, :read, sort: false, filter: false, page: false\n end)
      )

    assert_raise DslError, ~r/Message name "Note" is defined more than once/, fn ->
      AshGrpc.Schema.build([domain])
    end
  end

  test "an endpoint over an invalid domain does not compile" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :find, :find\n end),
        @resource
      )

    assert_raise DslError, ~r/has no action :find/, fn -> compile_endpoint(domain) end
  end

  @notifying ",\n    simple_notifiers: [AshGrpc.Notifier]"

  defp assert_invalid_subscription(grpc_body, message, resource \\ @resource) do
    domain = compile_domain(~s(package "notes.v1"\n) <> grpc_body, resource, @notifying)
    assert_raise DslError, message, fn -> AshGrpc.Schema.build([domain]) end
  end

  test "a subscription builds a streaming rpc over a read action" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n subscription INLINE, :watch_notes, :read, sort: false, filter: false\n end),
        @resource,
        @notifying
      )

    assert [%{services: [%{rpcs: [rpc]}]}] = AshGrpc.Schema.build([domain])
    assert rpc.stream?
    assert rpc.proto_name == "WatchNotes"

    assert Enum.map(rpc.response.fields, &{&1.name, &1.number, &1.repeated?}) == [
             {:result, 1, false},
             {:removed, 2, false},
             {:synced, 3, false},
             {:position, 4, false}
           ]
  end

  test "a subscription over an action that is not a read is rejected" do
    assert_invalid_subscription(
      ~s(service "Notes" do\n subscription INLINE, :watch, :create\n end),
      ~r/subscription :watch: action :create is not a read action/
    )
  end

  test "a subscription named like an rpc is rejected" do
    assert_invalid_subscription(
      ~s(service "Notes" do\n rpc INLINE, :list, :read, sort: false, filter: false, page: false\n subscription INLINE, :list, :read, sort: false, filter: false\n end),
      ~r/Rpc names repeat: \[:list\]/
    )
  end

  test "a subscription whose messages clash with an rpc's is rejected" do
    assert_invalid_subscription(
      ~s(service "Notes" do\n rpc INLINE, :watch_notes, :read, sort: false, filter: false, page: false\n subscription INLINE, :watchNotes, :read, sort: false, filter: false\n end),
      ~r/Message name "WatchNotesRequest" is defined more than once/
    )
  end

  test "repeated request field numbers on a subscription are rejected" do
    assert_invalid_subscription(
      ~s(service "Notes" do\n subscription INLINE, :watch, :read, args: [a: 1, b: 1], sort: false, filter: false\n end),
      ~r/Field numbers repeat: \[1\]/
    )
  end

  test "a subscription on a resource that does not list AshGrpc.Notifier compiles and gets the notifier" do
    resource = compile_resource(@resource)

    compile_domain(
      ~s(package "notes.v1"\nservice "Notes" do\n subscription #{inspect(resource)}, :watch, :read, sort: false, filter: false\n end)
    )

    assert AshGrpc.Notifier in Ash.Resource.Info.notifiers(resource)
  end

  test "a subscription on a resource whose primary key is not on the wire is rejected" do
    assert_invalid_subscription(
      ~s(service "Notes" do\n subscription INLINE, :watch, :read, sort: false, filter: false\n end),
      ~r/subscription :watch: the primary key \[:id\] must be in the resource's grpc `fields`/,
      String.replace(@resource, "fields id: 1, title: 2", "fields title: 2")
    )
  end
end
