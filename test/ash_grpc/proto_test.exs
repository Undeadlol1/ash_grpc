defmodule AshGrpc.ProtoTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile

  alias AshGrpc.TestSupport.Endpoint
  alias AshGrpc.TestSupport.Protoc
  alias Mix.Tasks.AshGrpc.Gen.Protos

  @resource """
  grpc do
    proto_message "Note"
    fields id: 1, title: 2, inserted_at: 3
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
    create_timestamp :inserted_at, public?: true
  end

  actions do
    defaults [:read, create: [:title]]
  end
  """

  @expected """
  syntax = "proto3";

  package notes.v1;

  import "google/protobuf/timestamp.proto";

  message Note {
    string id = 1;
    optional string title = 2;
    google.protobuf.Timestamp inserted_at = 3;
  }

  message ListNotesRequest {}

  message ListNotesResponse {
    repeated Note result = 1;
  }

  message AddNoteRequest {
    optional string title = 1;
  }

  message AddNoteResponse {
    Note result = 1;
  }

  service Notes {
    rpc ListNotes(ListNotesRequest) returns (ListNotesResponse);
    rpc AddNote(AddNoteRequest) returns (AddNoteResponse);
  }
  """

  @retired_resource """
  grpc do
    proto_message "Note"
    fields id: 1, title: 2
    reserved [7, 3]
    deprecated [:title]
  end

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, public?: true
  end

  actions do
    defaults [:read, create: [:title]]
  end
  """

  @retired_expected """
  syntax = "proto3";

  package notes.v1;

  message Note {
    string id = 1;
    optional string title = 2 [deprecated = true];
    reserved 3, 7;
  }

  message ListNotesRequest {}

  message ListNotesResponse {
    repeated Note result = 1;
  }

  message AddNoteRequest {
    optional string title = 1;
    reserved 2, 5;
  }

  message AddNoteResponse {
    Note result = 1;
  }

  message OnlyReservedRequest {
    reserved 4;
  }

  message OnlyReservedResponse {
    repeated Note result = 1;
  }

  service Notes {
    rpc ListNotes(ListNotesRequest) returns (ListNotesResponse) {
      option deprecated = true;
    }
    rpc AddNote(AddNoteRequest) returns (AddNoteResponse);
    rpc OnlyReserved(OnlyReservedRequest) returns (OnlyReservedResponse);
  }
  """

  defp retired_domain do
    compile_domain(
      ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :list_notes, :read, deprecated: true, sort: false, filter: false, page: false\n rpc INLINE, :add_note, :create, args: [title: 1], reserved: [5, 2]\n rpc INLINE, :only_reserved, :read, reserved: [4], sort: false, filter: false, page: false\n end),
      @retired_resource
    )
  end

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  test "renders one file per package from the domain" do
    domain =
      compile_domain(
        ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :list_notes, :read, sort: false, filter: false, page: false\n rpc INLINE, :add_note, :create, args: [title: 1]\n end),
        @resource
      )

    assert AshGrpc.Proto.render([domain]) == [{"notes/v1.proto", @expected}]
  end

  test "reserved numbers and deprecated fields and rpcs are rendered in order" do
    assert AshGrpc.Proto.render([retired_domain()]) == [{"notes/v1.proto", @retired_expected}]
  end

  @tag :protoc
  @tag :tmp_dir
  test "protoc accepts reserved numbers and deprecated fields and rpcs", %{tmp_dir: tmp_dir} do
    [{path, text}] = AshGrpc.Proto.render([retired_domain()])
    File.mkdir_p!(Path.join(tmp_dir, Path.dirname(path)))
    File.write!(Path.join(tmp_dir, path), text)

    assert {_output, 0} =
             System.cmd(
               Protoc.path(),
               ["--proto_path=#{tmp_dir}", "--descriptor_set_out=/dev/null", path],
               stderr_to_stdout: true
             )
  end

  test "an endpoint renders the files of its domains" do
    assert [{"blog/v1.proto", text}] = AshGrpc.Proto.render(Endpoint)
    assert text =~ "service Posts {"
    assert text =~ "  rpc ListPosts(ListPostsRequest) returns (ListPostsResponse);"
  end

  @tag :protoc
  @tag :tmp_dir
  test "protoc accepts the generated file", %{tmp_dir: tmp_dir} do
    [{path, text}] = AshGrpc.Proto.render(Endpoint)
    File.mkdir_p!(Path.join(tmp_dir, Path.dirname(path)))
    File.write!(Path.join(tmp_dir, path), text)

    assert {_output, 0} =
             System.cmd(
               Protoc.path(),
               ["--proto_path=#{tmp_dir}", "--descriptor_set_out=/dev/null", path],
               stderr_to_stdout: true
             )
  end

  @tag :tmp_dir
  test "the mix task writes the files and --check passes on them", %{tmp_dir: tmp_dir} do
    Protos.run(["--endpoint", inspect(Endpoint), "--output", tmp_dir])

    [{path, text}] = AshGrpc.Proto.render(Endpoint)
    assert File.read!(Path.join(tmp_dir, path)) == text
    assert Protos.run(["--endpoint", inspect(Endpoint), "--output", tmp_dir, "--check"]) == :ok
  end

  @tag :tmp_dir
  test "the mix task with --check fails on a drifted file", %{tmp_dir: tmp_dir} do
    Protos.run(["--endpoint", inspect(Endpoint), "--output", tmp_dir])
    File.write!(Path.join(tmp_dir, "blog/v1.proto"), "syntax = \"proto3\";\n")

    assert_raise Mix.Error, ~r/out of date: .*blog\/v1.proto/, fn ->
      Protos.run(["--endpoint", inspect(Endpoint), "--output", tmp_dir, "--check"])
    end
  end

  @tag :tmp_dir
  test "the mix task with --check fails on a missing file", %{tmp_dir: tmp_dir} do
    assert_raise Mix.Error, ~r/out of date/, fn ->
      Protos.run(["--endpoint", inspect(Endpoint), "--output", tmp_dir, "--check"])
    end
  end

  @streamed_expected """
  syntax = "proto3";

  package notes.v1;

  message Note {
    string id = 1;
    optional string title = 2;
  }

  message WatchNotesRequest {}

  message WatchNotesResponse {
    Note result = 1;
    bool removed = 2;
    bool synced = 3;
    optional uint32 position = 4;
  }

  message WatchOldNotesRequest {
    reserved 3;
  }

  message WatchOldNotesResponse {
    Note result = 1;
    bool removed = 2;
    bool synced = 3;
    optional uint32 position = 4;
  }

  service Notes {
    rpc WatchNotes(WatchNotesRequest) returns (stream WatchNotesResponse);
    rpc WatchOldNotes(WatchOldNotesRequest) returns (stream WatchOldNotesResponse) {
      option deprecated = true;
    }
  }
  """

  defp streamed_domain do
    compile_domain(
      ~s(package "notes.v1"\nservice "Notes" do\n subscription INLINE, :watch_notes, :read, sort: false, filter: false\n subscription INLINE, :watch_old_notes, :read, reserved: [3], deprecated: true, sort: false, filter: false\n end),
      String.replace(@retired_resource, "  reserved [7, 3]\n  deprecated [:title]\n", ""),
      ",\n    simple_notifiers: [AshGrpc.Notifier]"
    )
  end

  test "a subscription renders as a server-streaming rpc without meta" do
    assert AshGrpc.Proto.render([streamed_domain()], response_meta: true) ==
             [{"notes/v1.proto", @streamed_expected}]
  end

  @tag :protoc
  @tag :tmp_dir
  test "protoc accepts a subscription", %{tmp_dir: tmp_dir} do
    [{path, text}] = AshGrpc.Proto.render([streamed_domain()])
    File.mkdir_p!(Path.join(tmp_dir, Path.dirname(path)))
    File.write!(Path.join(tmp_dir, path), text)

    assert {_output, 0} =
             System.cmd(
               Protoc.path(),
               ["--proto_path=#{tmp_dir}", "--descriptor_set_out=/dev/null", path],
               stderr_to_stdout: true
             )
  end

  @tag :tmp_dir
  test "the mix task writes a subscription and refuses to turn it unary", %{tmp_dir: tmp_dir} do
    [{path, text}] = AshGrpc.Proto.render(AshGrpc.TestSupport.NotesEndpoint)
    assert text =~ "  rpc WatchNotes(WatchNotesRequest) returns (stream WatchNotesResponse);"

    File.mkdir_p!(Path.join(tmp_dir, Path.dirname(path)))

    File.write!(
      Path.join(tmp_dir, path),
      String.replace(text, "returns (stream WatchNotesResponse)", "returns (WatchNotesResponse)")
    )

    assert_raise Mix.Error,
                 ~r/rpc WatchNotes changed from .* to \(WatchNotesRequest\) returns \(stream WatchNotesResponse\)/,
                 fn ->
                   Protos.run([
                     "--endpoint",
                     "AshGrpc.TestSupport.NotesEndpoint",
                     "--output",
                     tmp_dir
                   ])
                 end
  end

  describe "descriptions" do
    @described_resource """
    resource do
      description "A note.\nSecond line."
    end

    grpc do
      proto_message "Note"
      fields id: 1, title: 2, shout: 3
    end

    attributes do
      uuid_primary_key :id, public?: true, description: "The id."
      attribute :title, :string, public?: true, description: "What it says.\nOn two lines."
    end

    calculations do
      calculate :shout, :string, expr(title <> "!"), public?: true, description: "Loud title."
    end

    actions do
      defaults [:read]

      create :add do
        description "Adds a note."
        accept [:title]
        argument :tone, :string, description: "How loud."
      end
    end
    """

    test "render as comment lines above the message, field and rpc" do
      domain =
        compile_domain(
          ~s(package "notes.v1"\nservice "Notes" do\n rpc INLINE, :add_note, :add, args: [title: 1, tone: 2]\n end),
          @described_resource
        )

      assert [{"notes/v1.proto", text}] = AshGrpc.Proto.render([domain])

      assert text =~ "// A note.\n// Second line.\nmessage Note {"
      assert text =~ "  // The id.\n  string id = 1;"
      assert text =~ "  // What it says.\n  // On two lines.\n  optional string title = 2;"
      assert text =~ "  // Loud title.\n  optional string shout = 3;"
      assert text =~ "  // What it says.\n  // On two lines.\n  optional string title = 1;"
      assert text =~ "  // How loud.\n  optional string tone = 2;"
      assert text =~ "  // Adds a note.\n  rpc AddNote(AddNoteRequest) returns (AddNoteResponse);"
    end
  end
end
