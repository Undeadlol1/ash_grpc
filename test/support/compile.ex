defmodule AshGrpc.TestSupport.Compile do
  @moduledoc false

  import ExUnit.CaptureIO

  def compile_resource(body, use_opts \\ "") do
    name = unique_name("Resource")
    compile(resource_source(name, body, use_opts))
    Module.concat([name])
  end

  def compile_domain(grpc_body, resource_body \\ nil, resource_use_opts \\ "") do
    resource = if resource_body, do: compile_resource(resource_body, resource_use_opts)
    grpc_body = String.replace(grpc_body, "INLINE", inspect(resource))
    name = unique_name("Domain")

    compile("""
    defmodule #{name} do
      use Ash.Domain, extensions: [AshGrpc.Domain], validate_config_inclusion?: false

      grpc do
        #{grpc_body}
      end
    end
    """)

    Module.concat([name])
  end

  def compile_endpoint(domain) do
    name = unique_name("Endpoint")

    compile("""
    defmodule #{name} do
      use AshGrpc.Endpoint, domains: [#{inspect(domain)}], authenticator: AshGrpc.TestSupport.Authenticator
    end
    """)

    Module.concat([name])
  end

  def resource_source(name, body, use_opts \\ "") do
    """
    defmodule #{name} do
      use Ash.Resource,
        domain: nil,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshGrpc.Resource],
        validate_domain_inclusion?: false#{use_opts}

      #{body}
    end
    """
  end

  def compile(source), do: capture_io(:stderr, fn -> Code.compile_string(source) end)

  defp unique_name(kind), do: "AshGrpc.Compiled.#{kind}#{System.unique_integer([:positive])}"
end
