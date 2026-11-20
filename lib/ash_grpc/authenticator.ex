defmodule AshGrpc.Authenticator do
  @moduledoc """
  Turns request headers into who is calling. The only source of identity:
  nothing the client sends reaches Ash any other way.

      defmodule MyApp.GrpcAuthenticator do
        @behaviour AshGrpc.Authenticator

        @impl true
        def authenticate(%{"authorization" => "Bearer " <> token}) do
          case MyApp.Tokens.verify(token) do
            {:ok, user} -> {:ok, actor: user, tenant: user.org}
            {:error, :keys_down} -> {:error, :unavailable}
            {:error, _} -> {:error, :unauthenticated}
          end
        end

        def authenticate(_headers), do: {:error, :unauthenticated}
      end

  `{:ok, opts}` may hold `:actor`, `:tenant` and `:context`; other keys are
  ignored. Authorization always runs. `{:error, :unauthenticated}` answers
  `UNAUTHENTICATED`, `{:error, :unavailable}` answers `UNAVAILABLE`, and
  `{:error, {:unavailable, retry_after_ms}}` answers `UNAVAILABLE` with the
  `grpc-retry-pushback-ms` header telling the client when to retry.

  Authentication runs before every interceptor of the endpoint, so a refused
  call reaches none of them. Interceptors read the result with
  `fetch_opts/1`.

  `authenticate/1` gets the request headers as a map with lowercase string
  keys. Anything else it returns is not an answer: if it raises, the call
  ends with `INTERNAL` and the cause is logged. See the
  [Authentication](authentication.md) guide.
  """

  @type headers :: %{optional(String.t()) => String.t()}
  @type opts :: [actor: term(), tenant: term(), context: map()]
  @type result ::
          {:ok, opts()}
          | {:error, :unauthenticated | :unavailable | {:unavailable, non_neg_integer()}}

  @doc """
  Decides who is calling from the request headers.

  Return `{:ok, opts}` with any of `:actor`, `:tenant` and `:context`, or
  `{:error, :unauthenticated}`, `{:error, :unavailable}` or
  `{:error, {:unavailable, retry_after_ms}}`.
  """
  @callback authenticate(headers()) :: result()

  @doc "What the authenticator answered for this call: `{:ok, opts}`, or `:error` before it ran."
  @spec fetch_opts(%GRPC.Server.Stream{}) :: {:ok, opts()} | :error
  def fetch_opts(%GRPC.Server.Stream{local: %{__MODULE__ => opts}}), do: {:ok, opts}
  def fetch_opts(%GRPC.Server.Stream{}), do: :error

  defmodule Interceptor do
    @moduledoc false
    @behaviour GRPC.Server.Interceptor

    @impl true
    def init(authenticator), do: authenticator

    @impl true
    def call(request, %{server: AshGrpc.Health.Server} = stream, next, _authenticator) do
      next.(request, stream)
    end

    def call(request, stream, next, authenticator) do
      opts = authenticate!(authenticator, stream)
      local = Map.put(stream.local || %{}, AshGrpc.Authenticator, opts)
      next.(request, %{stream | local: local})
    end

    defp authenticate!(authenticator, stream) do
      case authenticator.authenticate(stream.http_request_headers) do
        {:ok, opts} ->
          opts

        {:error, {:unavailable, retry_after_ms}}
        when is_integer(retry_after_ms) and retry_after_ms >= 0 ->
          GRPC.Server.set_headers(stream, %{
            "grpc-retry-pushback-ms" => Integer.to_string(retry_after_ms)
          })

          raise AshGrpc.Errors.to_rpc_error(:unavailable)

        {:error, reason} ->
          raise AshGrpc.Errors.to_rpc_error(reason)
      end
    rescue
      error in GRPC.RPCError -> reraise error, __STACKTRACE__
      error -> raise AshGrpc.Errors.internal(error, __STACKTRACE__)
    end
  end
end
