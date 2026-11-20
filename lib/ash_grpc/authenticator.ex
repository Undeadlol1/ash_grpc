defmodule AshGrpc.Authenticator do
  @moduledoc """
  Server-side authentication for ash_grpc requests.

  An authenticator inspects the raw request headers (e.g. an
  `authorization: Bearer <token>` header) and *derives* the Ash actor on
  the server. This is the trust anchor that makes gRPC safe to expose:
  unlike the `x-ash-actor` metadata convention — which lets a client claim
  any identity and is rejected on untrusted endpoints — an authenticator's
  actor comes from a verified credential the server controls.

  Configure one per endpoint via the `:authenticator` option passed to the
  transport, or globally with `config :ash_grpc, :authenticator, MyAuth`.

  Return values from `authenticate/2`:

    * `{:ok, actor}` — authenticated; `actor` becomes the Ash actor and
      overrides any client-supplied `x-ash-actor`.
    * `:anonymous` — no credentials presented; the request proceeds with a
      `nil` actor so Ash policies decide what anonymous access is allowed.
    * `{:error, reason}` — credentials were presented but invalid; the
      request is rejected with gRPC `unauthenticated`.
  """

  @type headers :: %{optional(String.t()) => String.t()}
  @type actor :: term()

  @callback authenticate(headers, opts :: keyword()) ::
              {:ok, actor} | :anonymous | {:error, term()}

  @doc """
  Resolves the configured authenticator module, if any.

  Precedence: explicit `:authenticator` option, then
  `config :ash_grpc, :authenticator`. Returns `nil` when no authenticator
  is configured (metadata-only mode).
  """
  @spec resolve(keyword()) :: module() | nil
  def resolve(options) do
    Keyword.get(options, :authenticator) || Application.get_env(:ash_grpc, :authenticator)
  end

  @doc """
  Runs the resolved authenticator against `headers`.

  Returns `{:ok, actor | nil}` on success (`nil` for anonymous or when no
  authenticator is configured) or `{:error, grpc_error}` on failure.
  """
  @spec authenticate(module() | nil, headers, keyword()) ::
          {:ok, actor | nil} | {:error, map()}
  def authenticate(nil, _headers, _options), do: {:ok, nil}

  def authenticate(module, headers, options) when is_atom(module) do
    case module.authenticate(headers, options) do
      {:ok, actor} -> {:ok, actor}
      :anonymous -> {:ok, nil}
      {:error, reason} -> {:error, unauthenticated(reason)}
    end
  end

  defp unauthenticated(reason) when is_binary(reason) do
    %{code: :unauthenticated, message: reason}
  end

  defp unauthenticated(_reason) do
    %{code: :unauthenticated, message: "authentication failed"}
  end
end
