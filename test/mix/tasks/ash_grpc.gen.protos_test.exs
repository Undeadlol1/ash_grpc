defmodule Mix.Tasks.AshGrpc.Gen.ProtosTest do
  use ExUnit.Case, async: true

  # The task reports written paths through `Mix.shell()`; capture it so the
  # suite prints nothing.
  import ExUnit.CaptureIO, only: [capture_io: 1]

  alias Mix.Tasks.AshGrpc.Gen.Protos

  @domain AshGrpc.Examples.SupportDesk
  @services [AshGrpc.Support.V1.Tickets.Service]

  describe "GIVEN Protos" do
    test "WHEN files are generated for a domain THEN one proto source is returned at its package path" do
      assert [{"ash_grpc/support/v1/tickets.proto", source}] =
               Protos.generate_files(@domain, @services)

      assert source =~ "service Tickets {"
      assert source =~ "message SubmitTicketRequest {"
    end

    test "WHEN the task runs with an output directory THEN the proto file is written under it" do
      output_dir =
        Path.join(System.tmp_dir!(), "ash_grpc_protos_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(output_dir) end)

      capture_io(fn ->
        Protos.run([
          "--domain",
          "AshGrpc.Examples.SupportDesk",
          "--service",
          "AshGrpc.Support.V1.Tickets.Service",
          "--output",
          output_dir
        ])
      end)

      written = Path.join(output_dir, "ash_grpc/support/v1/tickets.proto")
      assert File.exists?(written)
      assert File.read!(written) =~ "service Tickets {"
    end

    test "WHEN the check flag is given THEN it passes on current files and fails once a file drifts" do
      output_dir =
        Path.join(System.tmp_dir!(), "ash_grpc_protos_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf!(output_dir) end)

      argv = [
        "--domain",
        "AshGrpc.Examples.SupportDesk",
        "--service",
        "AshGrpc.Support.V1.Tickets.Service",
        "--output",
        output_dir
      ]

      capture_io(fn -> Protos.run(argv) end)
      capture_io(fn -> assert :ok == Protos.run(argv ++ ["--check"]) end)

      written = Path.join(output_dir, "ash_grpc/support/v1/tickets.proto")
      File.write!(written, "drifted\n")

      assert_raise Mix.Error, ~r/differ from disk/, fn ->
        Protos.run(argv ++ ["--check"])
      end
    end

    test "WHEN the domain or the service is missing THEN it raises that the missing option is required" do
      assert_raise Mix.Error, ~r/--domain is required/, fn ->
        Protos.run([])
      end

      assert_raise Mix.Error, ~r/--service is required/, fn ->
        Protos.run(["--domain", "AshGrpc.Examples.SupportDesk"])
      end
    end
  end
end
