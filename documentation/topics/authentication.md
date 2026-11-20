# Authentication

Every endpoint needs an authenticator: a module that implements the
`AshGrpc.Authenticator` behaviour. It is the only source of identity. The
actor, tenant and context of an Ash call come from it and from nowhere else;
nothing in the request message or in the headers reaches Ash any other way.
Authorization always runs.

```elixir
defmodule MyAppWeb.GrpcAuthenticator do
  @behaviour AshGrpc.Authenticator

  @impl true
  def authenticate(%{"authorization" => "Bearer " <> token}) do
    case MyApp.Tokens.verify(token) do
      {:ok, user} -> {:ok, actor: user, tenant: user.org_id}
      {:error, :keys_down} -> {:error, :unavailable}
      {:error, _reason} -> {:error, :unauthenticated}
    end
  end

  def authenticate(_headers), do: {:error, :unauthenticated}
end
```

```elixir
use AshGrpc.Endpoint, domains: [MyApp.Blog], authenticator: MyAppWeb.GrpcAuthenticator
```

`MyApp.Tokens` stands for your own code.

## The callback

`authenticate/1` is called once per call with the request headers: a map of
lowercase string keys to string values. A client sends them as gRPC metadata.
The `grpc-timeout` deadline header is among them.

| Returns | The call |
|---|---|
| `{:ok, opts}` | goes on. `opts` may hold `:actor`, `:tenant` and `:context`; other keys are ignored. |
| `{:error, :unauthenticated}` | ends with `UNAUTHENTICATED` |
| `{:error, :unavailable}` | ends with `UNAVAILABLE` |
| `{:error, {:unavailable, retry_after_ms}}` | ends with `UNAVAILABLE` and the `grpc-retry-pushback-ms` header set to `retry_after_ms` |
| anything else, or a raise | ends with `INTERNAL`, and the cause is logged |

Use `:unavailable` when you cannot tell: the token store is down, the keys did
not load. The client may retry. Use `:unauthenticated` when you can tell the
credentials are wrong.

When you know how long the outage lasts, answer
`{:error, {:unavailable, retry_after_ms}}` with a non-negative integer. The
client reads `grpc-retry-pushback-ms` from the response and may wait that long
before it retries. The header travels in the response headers of the refused
call, which gRPC reads as its trailers. A negative or non-integer value is not
an answer and ends the call with `INTERNAL`.

## Order

Authentication runs before every [interceptor](interceptors-and-response-meta.md)
of the endpoint. A refused call reaches none of them and no action.

An interceptor reads the answer with `AshGrpc.Authenticator.fetch_opts/1`,
which returns `{:ok, opts}`, or `:error` if no authenticator has run on that
stream.

## What reaches Ash

The options go to every Ash call of the request as `actor:`, `tenant:` and
`context:`, together with `authorize?: true`. That includes the record lookup
of an update or destroy, so a caller who may not read a record gets
`NOT_FOUND` for it.
