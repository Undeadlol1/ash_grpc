# Authentication

## Server-derived actor

Configure an `AshGrpc.Authenticator` to derive the Ash actor from verified
credentials on the server. The actor it returns **overrides** any
client-supplied `x-ash-actor`, so a client cannot assert its own identity.

```elixir
config :ash_grpc, authenticator: MyApp.GrpcAuthenticator

defmodule MyApp.GrpcAuthenticator do
  @behaviour AshGrpc.Authenticator

  def authenticate(%{"authorization" => "Bearer " <> token}, _opts) do
    case MyApp.Tokens.verify(token) do
      {:ok, user} -> {:ok, user}
      :error -> {:error, "invalid token"}
    end
  end

  def authenticate(_headers, _opts), do: :anonymous
end
```

- `{:ok, actor}` sets the actor.
- `:anonymous` runs with a `nil` actor, so your policies decide.
- `{:error, _}` rejects the call with `unauthenticated`.

You can also pass `authenticator:` as an option to `AshGrpc.Transport` calls.

## Request metadata trust

`x-ash-*` metadata sent over the wire (`x-ash-tenant`, `x-ash-context`,
`x-ash-actor`, `x-ash-authorize`) is **rejected by default** with
`permission_denied`.

Set `trust_request_metadata: true` only on an endpoint that sits behind an
authenticated internal gateway. With it on, `x-ash-actor` carries a JSON
object that your `actor_resolver` module turns into an actor:

```elixir
config :ash_grpc, actor_resolver: MyApp.GrpcActorResolver

defmodule MyApp.GrpcActorResolver do
  def resolve(%{"id" => id}), do: {:ok, MyApp.Accounts.get_user!(id)}
end
```

Options passed in-process (`:metadata`, `:actor`, `:tenant`, `:context`) are
always trusted.
