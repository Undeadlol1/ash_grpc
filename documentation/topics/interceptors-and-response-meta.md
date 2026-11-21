# Interceptors and response meta

Anything you do around every call (record request metadata, collect side
effects, add something to the response) is a `GRPC.Server.Interceptor`.

```elixir
use AshGrpc.Endpoint,
  domains: [MyApp.Blog],
  authenticator: MyAppWeb.GrpcAuthenticator,
  interceptors: [MyAppWeb.GrpcAudit, {MyAppWeb.GrpcEcho, header: "x-echo"}]
```

An entry is a module, or `{module, opts}`; `opts` go to the interceptor's
`init/1`.

```elixir
defmodule MyAppWeb.GrpcEcho do
  @behaviour GRPC.Server.Interceptor

  @impl true
  def init(opts), do: opts

  @impl true
  def call(request, stream, next, opts) do
    {:ok, ash_opts} = AshGrpc.Authenticator.fetch_opts(stream)
    echo = stream.http_request_headers[opts[:header]]
    reply = next.(request, stream)
    GRPC.Server.set_trailers(stream, %{"x-echo" => "#{echo} for #{ash_opts[:actor].name}"})
    reply
  end
end
```

## The rules

- **Authentication runs first.** A refused call reaches no interceptor.
  `AshGrpc.Authenticator.fetch_opts/1` gives the others the authenticator's
  `actor`, `tenant` and `context`.
- **The first interceptor listed is the outermost.** With `[A, B]`, `A` runs
  before `B` on the way in and after it on the way out.
- **Request metadata** is `stream.http_request_headers`, keys lowercase.
- **Rejecting a call**: raise a `GRPC.RPCError` with the status you want
  before calling `next`. The action does not run.

## Which process things run in

Interceptors run in the process that handles the call. Without a client
deadline every step runs in that process.

The remaining time of the deadline is the Ash `timeout` of every step: the
action, the record lookup of an update or destroy, and the calculation loads
(a generic action also runs under it). Ash runs a step with a timeout in a task
of its own when the data layer supports async work and the step is not already
inside a transaction; otherwise it runs inline in the calling process. When the
action runs in a transaction, the data layer transaction gets the timeout
instead of a task. Process state set by an interceptor (the process dictionary,
a collector) is therefore not visible to a step that runs in a task.

Do not rely on interceptor process state inside an action; use
`put_response_meta/2` with a function, which always runs in the interceptor's
process.

## Trailers

After `next` returns, `GRPC.Server.set_trailers/2` adds response trailers.
Each call replaces the trailers set before it in the same call, so one
interceptor should own them.

Trailers are for small values only. HTTP/2 header limits apply, and a trailer
larger than 4 KB breaks the connection. Anything that can grow goes in the
response meta below.

## Response meta

`response_meta: true` gives every response message of a unary call a field
`optional string meta = 2;`: a JSON document as text. It is a string rather
than `google.protobuf.Struct`, which turns every number into a double.

```elixir
use AshGrpc.Endpoint,
  domains: [MyApp.Blog],
  authenticator: MyAppWeb.GrpcAuthenticator,
  interceptors: [MyAppWeb.GrpcCollector],
  response_meta: true
```

Without the option nothing changes. Turning it on adds a field, which is a
compatible change (see [Evolving your schema](evolving-your-schema.md)).

An interceptor registers its part before `next`, as a function:

```elixir
def call(request, stream, next, _opts) do
  AshGrpc.Endpoint.put_response_meta(stream, fn -> %{"seen" => collect()} end)
  next.(request, stream)
end
```

The function runs after the action and its loads have finished, just before
the reply is built, in the process that handles the call. Process state set
before `next` is visible to it, also for actions that run in a task under a
deadline. It returns a map, or `nil` for nothing. A map can be passed instead
of a function when the value is already known.

All parts are merged at the top level in the order registered, a later one
winning a key, and encoded with Jason. If the merged map is empty, `meta` is
left unset (`nil` in Elixir). Unlike a trailer, `meta` is part of the
message: the library's tests send 100 KB through it intact. The usual gRPC
message size limits of the client and server apply.

On an endpoint without `response_meta: true`, `put_response_meta/2` raises
`ArgumentError`.

A failed call sends no reply, so it carries no meta.

A client reads it from the response:

```elixir
{:ok, %V1.CreatePostResponse{result: post, meta: meta}} = Stub.create_post(...)
Jason.decode!(meta)
```

## Call timing

The `grpc` package emits `:telemetry` events for every call it serves,
including those through AshGrpc, so there is nothing to configure here. Attach
your handlers as the package describes in its
[`GRPC.Telemetry` docs](https://hexdocs.pm/grpc/GRPC.Telemetry.html).
