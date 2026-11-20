defmodule Mix.Tasks.AshGrpc.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp installed, do: Igniter.compose_task(test_project(), "ash_grpc.install", [])

  defp diff_of(igniter, path), do: Igniter.Test.diff(igniter, only: path)

  test "creates the endpoint wired to the authenticator" do
    assert_creates(installed(), "lib/test_web/grpc_endpoint.ex", """
    defmodule TestWeb.GrpcEndpoint do
      @moduledoc "The gRPC endpoint. Add the domains to serve to `domains`."
      use AshGrpc.Endpoint,
        domains: [],
        authenticator: TestWeb.GrpcAuthenticator
    end
    """)
  end

  test "creates an authenticator that refuses every call" do
    diff = diff_of(installed(), "lib/test_web/grpc_authenticator.ex")

    assert diff =~ "@behaviour AshGrpc.Authenticator"
    assert diff =~ "def authenticate(_headers), do: {:error, :unauthenticated}"
  end

  test "starts the endpoint on port 50051 under the application" do
    diff = diff_of(installed(), "lib/test/application.ex")

    assert diff =~ "{TestWeb.GrpcEndpoint, [port: 50051]}"
  end

  test "configures the endpoint and the proto directory" do
    diff = diff_of(installed(), "config/config.exs")

    assert diff =~
             ~s(config :ash_grpc, endpoints: [TestWeb.GrpcEndpoint], proto_output: "priv/protos")
  end

  test "imports the formatter rules" do
    diff = diff_of(installed(), ".formatter.exs")

    assert diff =~ "import_deps: [:ash_grpc]"
  end

  test "running twice changes nothing" do
    installed()
    |> apply_igniter!()
    |> Igniter.compose_task("ash_grpc.install", [])
    |> assert_unchanged()
  end
end
