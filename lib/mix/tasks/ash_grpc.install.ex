if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshGrpc.Install do
    @shortdoc "Installs AshGrpc"

    @moduledoc """
    Installs AshGrpc. Should be run with `mix igniter.install ash_grpc`.

    Adds `:ash_grpc` to `import_deps`, creates `<YourAppWeb>.GrpcEndpoint` and a
    `<YourAppWeb>.GrpcAuthenticator` that refuses every call, starts the
    endpoint on port 50051 in the supervision tree, and sets the
    `:endpoints` and `:proto_output` configuration that
    `mix ash_grpc.gen.protos` and `mix ash.codegen` read.
    """
    use Igniter.Mix.Task

    alias Igniter.Libs.Phoenix
    alias Igniter.Project.Config

    @impl Igniter.Mix.Task
    def info(_argv, _parent), do: %Igniter.Mix.Task.Info{group: :ash}

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      endpoint = Phoenix.web_module_name(igniter, "GrpcEndpoint")
      authenticator = Phoenix.web_module_name(igniter, "GrpcAuthenticator")

      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_grpc)
      |> Spark.Igniter.prepend_to_section_order(:"Ash.Resource", [:grpc])
      |> Spark.Igniter.prepend_to_section_order(:"Ash.Domain", [:grpc])
      |> create_authenticator(authenticator)
      |> create_endpoint(endpoint, authenticator)
      |> Igniter.Project.Application.add_new_child({endpoint, port: 50_051})
      |> configure(endpoint)
      |> Igniter.add_notice("""
      AshGrpc is installed. Next:

        1. Add `extensions: [AshGrpc.Resource]` and a `grpc do fields ... end` block to a resource.
        2. Add `extensions: [AshGrpc.Domain]` and a `grpc do ... end` block with a service and rpcs to its domain, and list the domain in `domains: []` of #{inspect(endpoint)}.
        3. Return an actor from #{inspect(authenticator)}.authenticate/1.
        4. Run `mix ash_grpc.gen.protos` to write the .proto files to priv/protos.
      """)
    end

    defp create_authenticator(igniter, authenticator) do
      Igniter.Project.Module.create_module(igniter, authenticator, """
      @moduledoc \"\"\"
      Decides who is calling the gRPC endpoint. It refuses every call until you
      change it.

      `authenticate/1` gets the request headers as a map with lowercase string
      keys. Return `{:ok, actor: actor, tenant: tenant}` (both optional) for a
      caller you recognise, `{:error, :unauthenticated}` for one you do not, or
      `{:error, :unavailable}` when you cannot tell right now.
      \"\"\"
      @behaviour AshGrpc.Authenticator

      @impl true
      def authenticate(_headers), do: {:error, :unauthenticated}
      """)
    end

    defp create_endpoint(igniter, endpoint, authenticator) do
      Igniter.Project.Module.create_module(igniter, endpoint, """
      @moduledoc "The gRPC endpoint. Add the domains to serve to `domains`."
      use AshGrpc.Endpoint,
        domains: [],
        authenticator: #{inspect(authenticator)}
      """)
    end

    defp configure(igniter, endpoint) do
      igniter
      |> Config.configure(
        "config.exs",
        :ash_grpc,
        [:endpoints],
        [endpoint],
        updater: &Igniter.Code.List.append_new_to_list(&1, endpoint)
      )
      |> Config.configure_new(
        "config.exs",
        :ash_grpc,
        [:proto_output],
        "priv/protos"
      )
    end
  end
else
  defmodule Mix.Tasks.AshGrpc.Install do
    @shortdoc @moduledoc

    @moduledoc "Installs AshGrpc. Should be run with `mix igniter.install ash_grpc`."
    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_grpc.install' requires igniter to be run.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
