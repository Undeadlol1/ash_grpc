defmodule AshGrpc.TestSupport.RecordingInterceptor do
  @moduledoc false
  @behaviour GRPC.Server.Interceptor

  alias AshGrpc.TestSupport.Authenticator

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :name)

  @impl true
  def call(request, stream, next, name) do
    headers = stream.http_request_headers
    Authenticator.report(headers, {:before, name})
    Authenticator.report(headers, {:opts, name, AshGrpc.Authenticator.fetch_opts(stream)})

    if headers["x-reject"] == name do
      raise GRPC.RPCError, status: :failed_precondition, message: "Rejected by #{name}"
    end

    if headers["x-echo"], do: Process.put(__MODULE__, "#{headers["x-echo"]} via #{name}")

    result = next.(request, stream)
    Authenticator.report(headers, {:after, name})
    GRPC.Server.set_trailers(stream, %{"x-seen-by" => "#{headers["x-echo"]} via #{name}"})
    result
  end
end
