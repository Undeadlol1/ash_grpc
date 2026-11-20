defmodule AshGrpc.TlsTest do
  use ExUnit.Case, async: false

  alias AshGrpc.Health.HealthCheckRequest
  alias AshGrpc.Health.HealthCheckResponse
  alias AshGrpc.TestSupport.HealthEndpoint

  @certificate [digest: :sha256, key: {:namedCurve, :secp256r1}]

  defmodule Stub do
    @moduledoc false
    use GRPC.Stub, service: AshGrpc.Health.Service
  end

  setup do
    chain = %{root: @certificate, peer: @certificate}

    %{server_config: server_config, client_config: client_config} =
      :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})

    server_cred = GRPC.Credential.new(ssl: server_config)

    start_supervised!(
      {HealthEndpoint,
       port: 0,
       adapter_opts: [cred: server_cred, goaway_initial_timeout: 10, goaway_complete_timeout: 10]}
    )

    %{port: :ranch.get_port(inspect(HealthEndpoint)), client_config: client_config}
  end

  defp connect(port, opts) do
    {:ok, channel} = GRPC.Stub.connect("https://localhost:#{port}", opts)
    on_exit(fn -> GRPC.Stub.disconnect(channel) end)
    channel
  end

  defp check(channel), do: Stub.check(channel, %HealthCheckRequest{service: ""})

  test "a client that trusts the certificate makes a real call over TLS", %{
    port: port,
    client_config: config
  } do
    cred =
      GRPC.Credential.new(
        ssl: [
          cacerts: config[:cacerts],
          verify: :verify_peer,
          customize_hostname_check: [match_fun: fn _, _ -> true end]
        ]
      )

    channel = connect(port, cred: cred)

    assert {:ok, %HealthCheckResponse{status: :SERVING}} = check(channel)
  end

  test "a plaintext client cannot call a TLS endpoint", %{port: port} do
    result =
      case GRPC.Stub.connect("localhost:#{port}") do
        {:ok, channel} -> check(channel)
        {:error, _reason} = error -> error
      end

    assert {:error, _reason} = result
  end
end
