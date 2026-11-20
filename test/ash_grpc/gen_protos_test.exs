defmodule AshGrpc.GenProtosTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.Compile

  alias Mix.Tasks.AshGrpc.Gen.Protos
  alias Spark.Error.DslError

  defp endpoint(grpc_lines, package \\ "notes.v1") do
    resource = """
    grpc do
      proto_message "Note"
      #{grpc_lines}
    end

    attributes do
      uuid_primary_key :id, public?: true
      attribute :title, :string, public?: true
      attribute :body, :string, public?: true
      attribute :slug, :string, public?: true
    end

    actions do
      defaults [:read]
    end
    """

    domain =
      compile_domain(
        ~s(package "#{package}"\nservice "Notes" do\n rpc INLINE, :list_notes, :read, sort: false, filter: false, page: false\n end),
        resource
      )

    compile_endpoint(domain)
  end

  defp run(endpoint, output, extra \\ []) do
    Protos.run(["--endpoint", inspect(endpoint), "--output", output] ++ extra)
  end

  defp file(output), do: Path.join(output, "notes/v1.proto")

  test "neither flags nor configuration fails naming both ways" do
    error = assert_raise Mix.Error, fn -> Protos.run([]) end

    assert error.message =~ "--endpoint and --output"
    assert error.message =~ "config :ash_grpc, endpoints:"
  end

  test "a flag without its partner and without configuration fails" do
    assert_raise Mix.Error, ~r/No endpoint or output/, fn -> Protos.run(["--output", "x"]) end

    assert_raise Mix.Error, ~r/No endpoint or output/, fn ->
      Protos.run(["--endpoint", "Some.Endpoint"])
    end
  end

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    %{committed: endpoint("fields id: 1, title: 2, body: 3")}
  end

  @moduletag :tmp_dir

  test "a removed field whose number is not reserved is refused and the file is untouched", %{
    tmp_dir: dir,
    committed: committed
  } do
    run(committed, dir)
    before = File.read!(file(dir))

    error =
      assert_raise Mix.Error, fn -> run(endpoint("fields id: 1, title: 2"), dir) end

    assert error.message =~ "Nothing written"
    assert error.message =~ "field 3 (`optional string body`) was removed"
    assert error.message =~ "Add `reserved 3` to Note"
    assert File.read!(file(dir)) == before
  end

  test "--allow-breaking writes the breaking change", %{tmp_dir: dir, committed: committed} do
    run(committed, dir)
    run(endpoint("fields id: 1, title: 2"), dir, ["--allow-breaking"])

    refute File.read!(file(dir)) =~ "body"
  end

  test "retiring a field by reserving its number is written", %{
    tmp_dir: dir,
    committed: committed
  } do
    run(committed, dir)
    run(endpoint("fields id: 1, title: 2\nreserved [3]"), dir)

    assert File.read!(file(dir)) =~ "reserved 3;"
  end

  test "adding a field is written", %{tmp_dir: dir, committed: committed} do
    run(committed, dir)
    run(endpoint("fields id: 1, title: 2, body: 3, slug: 4"), dir)

    assert File.read!(file(dir)) =~ "optional string slug = 4;"
  end

  test "a first run writes without comparing", %{tmp_dir: dir, committed: committed} do
    run(committed, dir)

    assert File.exists?(file(dir))
  end

  test "a committed file the task cannot read is refused", %{tmp_dir: dir, committed: committed} do
    File.mkdir_p!(Path.dirname(file(dir)))
    File.write!(file(dir), "syntax = \"proto3\";\nenum Color {}\n")

    assert_raise Mix.Error, ~r/is not a file this task wrote: cannot read .proto line 2/, fn ->
      run(committed, dir)
    end
  end

  test "a package renamed away leaves a file the guard refuses to orphan", %{
    tmp_dir: dir,
    committed: committed
  } do
    run(committed, dir)
    renamed = endpoint("fields id: 1, title: 2, body: 3", "memos.v1")

    error = assert_raise Mix.Error, fn -> run(renamed, dir) end

    assert error.message =~ "Nothing written"
    assert error.message =~ "notes/v1.proto"
    assert error.message =~ "no longer rendered"
    assert File.exists?(file(dir))
    refute File.exists?(Path.join(dir, "memos/v1.proto"))
  end

  test "--allow-breaking deletes the file nothing renders any more", %{
    tmp_dir: dir,
    committed: committed
  } do
    run(committed, dir)
    run(endpoint("fields id: 1, title: 2, body: 3", "memos.v1"), dir, ["--allow-breaking"])

    refute File.exists?(file(dir))
    assert File.exists?(Path.join(dir, "memos/v1.proto"))
  end

  test "--check fails on a file nothing renders any more", %{tmp_dir: dir, committed: committed} do
    run(committed, dir)
    run(endpoint("fields id: 1, title: 2, body: 3", "memos.v1"), dir, ["--allow-breaking"])
    File.write!(file(dir), "stray")

    assert_raise Mix.Error, ~r/notes\/v1.proto/, fn ->
      run(endpoint("fields id: 1, title: 2, body: 3", "memos.v1"), dir, ["--check"])
    end
  end

  test "--check still means the committed file equals the rendered text", %{
    tmp_dir: dir,
    committed: committed
  } do
    run(committed, dir)

    assert run(committed, dir, ["--check"]) == :ok

    assert_raise Mix.Error, ~r/out of date/, fn ->
      run(endpoint("fields id: 1, title: 2"), dir, ["--check"])
    end
  end

  describe "configuration" do
    setup do
      on_exit(fn ->
        Application.delete_env(:ash_grpc, :endpoints)
        Application.delete_env(:ash_grpc, :proto_output)
      end)
    end

    test "endpoints and output come from the application environment", %{
      tmp_dir: dir,
      committed: committed
    } do
      Application.put_env(:ash_grpc, :endpoints, [committed])
      Application.put_env(:ash_grpc, :proto_output, dir)

      Protos.run([])

      assert File.read!(file(dir)) =~ "optional string body = 3;"
      assert Protos.run(["--check"]) == :ok
    end

    test "flags win over the configuration", %{tmp_dir: dir, committed: committed} do
      Application.put_env(:ash_grpc, :endpoints, [Some.Other.Endpoint])
      Application.put_env(:ash_grpc, :proto_output, Path.join(dir, "unused"))

      run(committed, dir)

      assert File.exists?(file(dir))
      refute File.exists?(Path.join(dir, "unused"))
    end

    test "several configured endpoints share one output directory", %{tmp_dir: dir} do
      notes = endpoint("fields id: 1, title: 2, body: 3")
      memos = endpoint("fields id: 1, title: 2, body: 3", "memos.v1")
      Application.put_env(:ash_grpc, :endpoints, [notes, memos])
      Application.put_env(:ash_grpc, :proto_output, dir)

      Protos.run([])

      assert File.exists?(file(dir))
      assert File.exists?(Path.join(dir, "memos/v1.proto"))
      assert Protos.run(["--check"]) == :ok
    end

    test "two endpoints rendering one package differently are refused by name", %{tmp_dir: dir} do
      whole = endpoint("fields id: 1, title: 2, body: 3")
      partial = endpoint("fields id: 1, title: 2")
      Application.put_env(:ash_grpc, :endpoints, [whole, partial])
      Application.put_env(:ash_grpc, :proto_output, dir)

      error = assert_raise Mix.Error, ~r/notes\/v1.proto/, fn -> Protos.run([]) end

      assert error.message =~ inspect(whole)
      assert error.message =~ inspect(partial)
      refute File.exists?(file(dir))
    end

    test "two endpoints rendering one package identically write it once", %{tmp_dir: dir} do
      Application.put_env(:ash_grpc, :endpoints, [
        endpoint("fields id: 1, title: 2"),
        endpoint("fields id: 1, title: 2")
      ])

      Application.put_env(:ash_grpc, :proto_output, dir)

      Protos.run([])

      assert Protos.run(["--check"]) == :ok
    end
  end

  describe "automatic numbers" do
    setup %{tmp_dir: dir} do
      Application.put_env(:ash_grpc, :proto_output, dir)
      on_exit(fn -> Application.delete_env(:ash_grpc, :proto_output) end)
    end

    defp field_numbers(text) do
      for [_, name, number] <- Regex.scan(~r/ (\w+) = (\d+)(?: \[deprecated = true\])?;/, text),
          into: %{},
          do: {name, String.to_integer(number)}
    end

    test "GIVEN no committed file WHEN generated THEN fields are numbered 1..n", %{tmp_dir: dir} do
      run(endpoint("fields [:id, :title, :body]"), dir)

      assert %{"id" => 1, "title" => 2, "body" => 3} = field_numbers(File.read!(file(dir)))
    end

    test "GIVEN a committed file WHEN a field is appended THEN old numbers stay and the new one is next",
         %{tmp_dir: dir} do
      run(endpoint("fields [:id, :title, :body]"), dir)
      run(endpoint("fields [:id, :title, :body, :slug]"), dir)

      assert %{"id" => 1, "title" => 2, "body" => 3, "slug" => 4} =
               field_numbers(File.read!(file(dir)))
    end

    test "GIVEN a removed field WHEN regenerated twice THEN its number stays reserved and is not reused",
         %{tmp_dir: dir} do
      run(endpoint("fields [:id, :title, :body]"), dir)
      run(endpoint("fields [:id, :title]"), dir)

      assert_received {:mix_shell, :info,
                       ["Retired Note.body (field 3); its number is now reserved."]}

      run(endpoint("fields [:id, :title, :slug]"), dir)
      text = File.read!(file(dir))

      assert text =~ "reserved 3;"
      assert %{"slug" => 4} = field_numbers(text)
      refute Map.has_key?(field_numbers(text), "body")
    end

    test "GIVEN nothing changed WHEN generated again THEN nothing is written and --check passes",
         %{tmp_dir: dir} do
      run(endpoint("fields [:id, :title]"), dir)
      unchanged = endpoint("fields [:id, :title]")
      Mix.shell().flush()

      run(unchanged, dir)

      refute_received {:mix_shell, :info, ["Wrote " <> _path]}
      assert run(unchanged, dir, ["--check"]) == :ok

      assert_raise Mix.Error, ~r/out of date/, fn ->
        run(endpoint("fields [:id, :title, :body]"), dir, ["--check"])
      end

      run(endpoint("fields [:id, :title, :body]"), dir)

      assert run(endpoint("fields [:id, :title, :body]"), dir, ["--check"]) == :ok
    end

    test "GIVEN a generated file WHEN the endpoint serves THEN its field numbers are the file's",
         %{tmp_dir: dir} do
      run(endpoint("fields [:id, :title]"), dir)
      served = endpoint("fields [:slug, :id, :body, :title]")
      run(served, dir)

      props = Module.concat([served, "Notes", "V1", "Note"]).__message_props__().field_props
      served_numbers = Map.new(props, fn {number, prop} -> {prop.name, number} end)

      assert served_numbers ==
               dir
               |> file()
               |> File.read!()
               |> field_numbers()
               |> Map.take(Map.keys(served_numbers))

      assert map_size(served_numbers) == 4
    end

    test "GIVEN an unparseable committed file WHEN the endpoint compiles THEN it stops naming the file",
         %{tmp_dir: dir} do
      File.mkdir_p!(Path.dirname(file(dir)))
      File.write!(file(dir), "nonsense\n")

      assert_raise DslError, ~r/notes\/v1.proto.*cannot be read/s, fn ->
        endpoint("fields [:id, :title]")
      end
    end

    test "GIVEN no proto_output WHEN an endpoint has an un-numbered field THEN it does not compile" do
      Application.delete_env(:ash_grpc, :proto_output)

      assert_raise DslError, ~r/config :ash_grpc, proto_output/, fn ->
        endpoint("fields [:id, :title]")
      end
    end
  end

  describe "mix ash.codegen" do
    setup do
      on_exit(fn ->
        Application.delete_env(:ash_grpc, :endpoints)
        Application.delete_env(:ash_grpc, :proto_output)
      end)
    end

    test "writes the protos, and --check passes then fails when stale", %{
      tmp_dir: dir,
      committed: committed
    } do
      Application.put_env(:ash_grpc, :endpoints, [committed])
      Application.put_env(:ash_grpc, :proto_output, dir)

      assert_raise Mix.Error, ~r/out of date/, fn ->
        AshGrpc.Domain.codegen(["--check", "--name", "nil"])
      end

      AshGrpc.Domain.codegen(["--name", "nil", "--dev"])

      assert File.exists?(file(dir))
      assert AshGrpc.Domain.codegen(["--check"]) == :ok

      File.write!(file(dir), "stale")

      assert_raise Mix.Error, ~r/out of date/, fn -> AshGrpc.Domain.codegen(["--check"]) end
    end

    test "is silent about protos while nothing is configured" do
      AshGrpc.Domain.codegen(["--check"])

      assert_received {:mix_shell, :info, [message]}
      assert message =~ "Skipping .proto files"
    end
  end
end
