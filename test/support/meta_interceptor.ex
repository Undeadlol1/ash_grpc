defmodule AshGrpc.TestSupport.MetaInterceptor do
  @moduledoc false
  @behaviour GRPC.Server.Interceptor

  @impl true
  def init(opts), do: Keyword.fetch!(opts, :name)

  @impl true
  def call(request, stream, next, name) do
    headers = stream.http_request_headers

    if !headers["x-no-meta"] do
      AshGrpc.Endpoint.put_response_meta(stream, fn ->
        %{name => meta_for(headers), "shared" => name}
      end)
    end

    next.(request, stream)
  end

  defp meta_for(%{"x-meta-bytes" => bytes}), do: String.duplicate("x", String.to_integer(bytes))
  defp meta_for(%{"x-meta-text" => _}), do: "Привет, мир ✓"
  defp meta_for(_headers), do: 1
end
