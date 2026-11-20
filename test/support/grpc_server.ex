defmodule AshGrpc.TestSupport.GrpcServer do
  @moduledoc false

  import ExUnit.Callbacks

  @quick_close [goaway_initial_timeout: 10, goaway_complete_timeout: 10]

  def start(endpoint \\ AshGrpc.TestSupport.Endpoint, connect_opts \\ []) do
    start_supervised!(
      Supervisor.child_spec({endpoint, port: 0, adapter_opts: @quick_close}, id: endpoint)
    )

    port = :ranch.get_port(inspect(endpoint))
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{port}", connect_opts)
    on_exit(fn -> GRPC.Stub.disconnect(channel) end)
    channel
  end

  def signed_in(name, extra \\ %{}), do: Map.merge(%{"authorization" => "Bearer #{name}"}, extra)
end
