defmodule AshGrpc.Cors do
  @moduledoc false

  # Wraps the stock CORS interceptor so a preflight ends here, before authentication.
  @behaviour GRPC.Server.Interceptor

  alias GRPC.Server.Interceptors.CORS

  @impl true
  def init(opts), do: CORS.init(opts)

  @impl true
  def call(request, stream, next, state) do
    CORS.call(request, stream, &answer(&1, &2, next), state)
  end

  defp answer(_request, %{is_preflight?: true} = stream, _next), do: {:ok, stream, []}

  defp answer(request, stream, next), do: next.(request, stream)
end
