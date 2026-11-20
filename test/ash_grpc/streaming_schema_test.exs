defmodule AshGrpc.StreamingSchemaTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile
  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.Proto.Compatibility
  alias AshGrpc.TestSupport.Protoc
  alias AshGrpc.TestSupport.StreamEndpoint
  alias Google.Protobuf.FileDescriptorProto
  alias Grpc.Reflection.V1.ServerReflection.Stub
  alias Grpc.Reflection.V1.ServerReflectionRequest
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
    defaults [:read, :destroy, create: [:title]]

    update :edit do
      accept [:title]
    end

    action :ping do
      run fn _input, _context -> :ok end
    end
  end
  """

  @status_proto """
  syntax = "proto3";
  package google.rpc;
  import "google/protobuf/any.proto";
  message Status {
    int32 code = 1;
    string message = 2;
    repeated google.protobuf.Any details = 3;
  }
  """

  defp proto_for(grpc_body) do
    domain =
      compile_domain(~s(package "notes.v1"\nservice "Notes" do\n#{grpc_body}\nend), @resource)

    assert [{_path, text}] = AshGrpc.Proto.render([domain])
    text
  end

  defp assert_invalid(grpc_body, message) do
    domain =
      compile_domain(~s(package "notes.v1"\nservice "Notes" do\n#{grpc_body}\nend), @resource)

    assert_raise DslError, message, fn -> AshGrpc.Schema.build([domain]) end
  end

  describe "verifier" do
    test "streaming cannot be combined with bulk?" do
      assert_invalid(
        "rpc INLINE, :add_all, :create, bulk?: true, streaming: :client, args: [title: 1]",
        ~r/rpc :add_all: `streaming` cannot be combined with `bulk\?`/
      )
    end

    test "a subscription takes no streaming option" do
      assert_raise DslError, ~r/streaming/, fn ->
        compile_domain(
          ~s(package "notes.v1"\nservice "Notes" do\nsubscription INLINE, :watch, :read, streaming: :client\nend),
          @resource
        )
      end
    end

    test "client streaming is refused on a read action" do
      assert_invalid(
        "rpc INLINE, :look, :read, streaming: :client, args: [], sort: false, filter: false, page: false",
        ~r/rpc :look: `streaming: :client` needs an action that writes; :read is a read action/
      )
    end

    test "bidirectional streaming is allowed on every action type" do
      text =
        proto_for("""
        rpc INLINE, :add, :create, streaming: :bidirectional, args: [title: 1]
        rpc INLINE, :change, :edit, streaming: :bidirectional, args: [id: 1, title: 2], clear_fields: 3
        rpc INLINE, :remove, :destroy, streaming: :bidirectional, args: [id: 1]
        rpc INLINE, :look, :read, streaming: :bidirectional, args: [id: 1]
        rpc INLINE, :ping, :ping, streaming: :bidirectional
        """)

      for name <- ~w(Add Change Remove Look Ping) do
        assert text =~ "rpc #{name}(stream #{name}Request) returns (stream #{name}Reply);"
      end
    end

    test "client streaming is allowed on create, update, destroy and generic actions" do
      text =
        proto_for("""
        rpc INLINE, :add, :create, streaming: :client, args: [title: 1]
        rpc INLINE, :change, :edit, streaming: :client, args: [id: 1, title: 2], clear_fields: 3
        rpc INLINE, :remove, :destroy, streaming: :client, args: [id: 1]
        rpc INLINE, :ping, :ping, streaming: :client
        """)

      for name <- ~w(Add Change Remove Ping) do
        assert text =~ "rpc #{name}(stream #{name}Request) returns (#{name}Summary);"
      end
    end

    test "max_stream_failures needs streaming: :client" do
      assert_invalid(
        "rpc INLINE, :add, :create, args: [title: 1], max_stream_failures: 5",
        ~r/rpc :add: `max_stream_failures` only applies with `streaming: :client`/
      )

      assert_invalid(
        "rpc INLINE, :add, :create, streaming: :bidirectional, args: [title: 1], max_stream_failures: 5",
        ~r/rpc :add: `max_stream_failures` only applies with `streaming: :client`/
      )
    end

    for value <- ["0", "-1", "1.5", ~s("many")] do
      test "max_stream_failures #{value} is refused" do
        assert_raise DslError, ~r/max_stream_failures/, fn ->
          compile_domain(
            ~s(package "notes.v1"\nservice "Notes" do\nrpc INLINE, :add, :create, streaming: :client, args: [title: 1], max_stream_failures: #{unquote(value)}\nend),
            @resource
          )
        end
      end
    end

    test "streaming takes only :client or :bidirectional" do
      assert_raise DslError, ~r/streaming/, fn ->
        compile_domain(
          ~s(package "notes.v1"\nservice "Notes" do\nrpc INLINE, :add, :create, streaming: :server, args: [title: 1]\nend),
          @resource
        )
      end
    end
  end

  describe "generated proto" do
    test "a bidirectional rpc streams both sides and replies with the response or an error" do
      text = proto_for("rpc INLINE, :add, :create, streaming: :bidirectional, args: [title: 1]")

      assert text =~ ~s(import "google/rpc/status.proto";)
      assert text =~ "message AddRequest {\n  optional string title = 1;\n}"
      assert text =~ "message AddResponse {\n  Note result = 1;\n}"

      assert text =~
               "message AddReply {\n  uint32 index = 1;\n  oneof outcome {\n    AddResponse result = 2;\n    google.rpc.Status error = 3;\n  }\n}"

      assert text =~ "rpc Add(stream AddRequest) returns (stream AddReply);"
    end

    test "a client-streaming rpc answers a summary of the failures" do
      text = proto_for("rpc INLINE, :add, :create, streaming: :client, args: [title: 1]")

      assert text =~
               "message AddSummary {\n  uint32 succeeded = 1;\n  repeated AddFailure failures = 2;\n}"

      assert text =~
               "message AddFailure {\n  uint32 index = 1;\n  google.rpc.Status error = 2;\n}"

      assert text =~ "rpc Add(stream AddRequest) returns (AddSummary);"
      refute text =~ "message AddResponse"
    end

    test "a streaming rpc never carries meta" do
      domain =
        compile_domain(
          ~s(package "notes.v1"\nservice "Notes" do\nrpc INLINE, :add, :create, streaming: :bidirectional, args: [title: 1]\nend),
          @resource
        )

      assert [{_path, text}] = AshGrpc.Proto.render([domain], response_meta: true)
      refute text =~ "meta"
    end

    @tag :protoc
    @tag :tmp_dir
    test "protoc accepts both modes", %{tmp_dir: tmp_dir} do
      text =
        proto_for("""
        rpc INLINE, :add, :create, streaming: :bidirectional, args: [title: 1]
        rpc INLINE, :import, :create, streaming: :client, args: [title: 1]
        """)

      File.mkdir_p!(Path.join(tmp_dir, "notes"))
      File.write!(Path.join(tmp_dir, "notes/v1.proto"), text)
      File.mkdir_p!(Path.join(tmp_dir, "google/rpc"))
      File.write!(Path.join(tmp_dir, "google/rpc/status.proto"), @status_proto)

      assert {_output, 0} =
               System.cmd(
                 Protoc.path(),
                 ["--proto_path=#{tmp_dir}", "--descriptor_set_out=/dev/null", "notes/v1.proto"],
                 stderr_to_stdout: true
               )
    end
  end

  describe "breaking changes" do
    defp rendered(mode) do
      option = if mode, do: ", streaming: #{inspect(mode)}", else: ""
      proto_for("rpc INLINE, :add, :create, args: [title: 1]#{option}")
    end

    test "turning a unary rpc into a streaming one is breaking, and so is the way back" do
      for mode <- [:client, :bidirectional] do
        assert Enum.any?(
                 Compatibility.check(rendered(nil), rendered(mode)),
                 &(&1 =~
                     "rpc Add changed from (AddRequest) returns (AddResponse) to (stream AddRequest)")
               )

        assert Compatibility.check(rendered(mode), rendered(nil)) != :ok
      end
    end

    test "changing the mode is breaking" do
      assert Compatibility.check(rendered(:client), rendered(:bidirectional)) != :ok
      assert Compatibility.check(rendered(:bidirectional), rendered(:client)) != :ok
    end

    test "the same mode is compatible" do
      for mode <- [nil, :client, :bidirectional],
          do: assert(Compatibility.check(rendered(mode), rendered(mode)) == :ok)
    end
  end

  describe "reflection" do
    test "lists the streaming flags of each rpc" do
      channel = start(StreamEndpoint)
      stream = Stub.server_reflection_info(channel, metadata: signed_in("reader"))

      request = %ServerReflectionRequest{
        message_request: {:file_containing_symbol, "stream.v1.Entries"}
      }

      GRPC.Stub.send_request(stream, request, end_stream: true)
      {:ok, replies} = GRPC.Stub.recv(stream)

      [{:ok, %{message_response: {:file_descriptor_response, %{file_descriptor_proto: [bytes]}}}}] =
        Enum.to_list(replies)

      [service] = FileDescriptorProto.decode(bytes).service
      methods = Map.new(service.method, &{&1.name, &1})

      assert %{client_streaming: true, server_streaming: true} = methods["PostEntries"]
      assert %{client_streaming: true, server_streaming: server} = methods["ImportEntries"]
      assert server in [false, nil]
      assert %{client_streaming: client} = methods["ListEntries"]
      assert client in [false, nil]
    end
  end
end
