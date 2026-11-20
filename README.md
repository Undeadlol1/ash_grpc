# AshGrpc

[![CI](https://github.com/Undeadlol1/ash_grpc/actions/workflows/ci.yml/badge.svg)](https://github.com/Undeadlol1/ash_grpc/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/Undeadlol1/ash_grpc/blob/main/LICENSE)

Serve [Ash](https://hexdocs.pm/ash) actions over gRPC. You declare the routes on
an Ash domain, bind each one to an action, and AshGrpc turns protobuf requests
into Ash inputs and Ash results back into protobuf replies.

## TL;DR

```elixir
defmodule MyApp.Support do
  use Ash.Domain, extensions: [AshGrpc.Domain]

  grpc do
    routes do
      service "/my_app.support.v1.Tickets" do
        unary :submit_ticket, MyApp.Support.Ticket, :create,
          response_mapper: MyApp.Support.ReplyMapper

        server_stream :stream_tickets, MyApp.Support.Ticket, :read,
          request_mapper: MyApp.Support.ListMapper,
          response_mapper: MyApp.Support.ReplyMapper
      end
    end
  end

  resources do
    resource MyApp.Support.Ticket do
      define :submit_ticket, action: :create, args: [:subject, :body]
    end
  end
end
```

Your generated `GRPC.Server` module then hands each call to AshGrpc:

```elixir
def submit_ticket(request, stream) do
  MyApp.Support
  |> AshGrpc.Transport.handle_unary(:submit_ticket, request, grpc_stream: stream)
  |> AshGrpc.Transport.unwrap_response()
end
```

## Features

- **Routes live on the domain.** `unary`, `server_stream`, `client_stream`
  and `bidirectional_stream` routes are declared next to the actions they run.
- **Server-derived identity.** An `AshGrpc.Authenticator` turns verified
  credentials into the Ash actor; a client cannot claim its own identity.
- **Deadlines.** The `grpc-timeout` header becomes an Ash `:timeout`.
- **Real gRPC errors.** Ash errors map to gRPC statuses, and validation
  failures carry per-field details.
- **Lists.** `AshGrpc.ListQuery` turns a standard list request into a safe
  `Ash.Query`.
- **`.proto` files.** `mix ash_grpc.gen.protos` writes them from your routes
  so clients in other languages can be generated.

## Installation

AshGrpc is not on Hex yet. Add it from GitHub in `mix.exs`:

```elixir
def deps do
  [
    {:ash_grpc, github: "Undeadlol1/ash_grpc"}
  ]
end
```

AshGrpc depends on `grpc`, `grpc_server`, `grpc_reflection` and `protobuf`.
To use `AshGrpc.PubSubSource`, also add `{:phoenix_pubsub, "~> 2.1"}` and
`{:phoenix, "~> 1.7"}` (the broadcast struct lives in Phoenix). A gRPC
client built on `GRPC.Stub.connect/2` needs `{:gun, "~> 2.4"}`.

## Mappers

Each route can name a `request_mapper` and a `response_mapper`. A request
mapper turns the protobuf request into the Ash input (a map, or a list of
positional arguments for a code interface); a response mapper turns the
result into the reply.

Unary routes fall back to `AshGrpc.InferredRequestMapper` and
`AshGrpc.InferredResponseMapper` when none is given. Streaming routes need
explicit mappers. `handler:` replaces the domain code interface for a route.

## Deadlines

The standard `grpc-timeout` header is parsed by `AshGrpc.Deadline` and passed
to Ash as a millisecond `:timeout`, so actions stop at the client's deadline.
Server streams stop emitting once the deadline passes.

## Errors

`AshGrpc.ErrorMapper` maps Ash errors to gRPC statuses. Validation failures
also produce `google.rpc.BadRequest.FieldViolation` details on the
`grpc-status-details-bin` trailer, so clients can show errors next to the
field. Build errors with `AshGrpc.ErrorMapper.to_rpc_error/1`.

## Listing

`AshGrpc.ListQuery.build/2` turns a standard list request (`order_by`,
`page_size`, `page_offset`, `filter`) into an `Ash.Query` using Ash's input
builders, which are made for untrusted values.

## Configuration

| Key | Meaning |
| --- | --- |
| `config :ash_grpc, authenticator: Module` | Derives the actor from request headers. See [Authentication](documentation/topics/authentication.md). |
| `config :ash_grpc, actor_resolver: Module` | Resolves a trusted `x-ash-actor` payload into an actor. Only used when `trust_request_metadata: true`. |

Both can also be passed per call as the `:authenticator` and
`:actor_resolver` options.

## Not included

- **A running endpoint.** Put `GRPC.Server.Supervisor` in your own supervision
  tree with your port and interceptors.
- **TLS and mTLS.** Configure channel credentials for your environment.
- **A health service** (`grpc.health.v1.Health`), which most load balancers
  expect.
- **Protobuf messages from Ash attributes.** Messages are declared by hand.

## Documentation

- [Authentication](documentation/topics/authentication.md)
- [Streaming](documentation/topics/streaming.md)
- [Generating .proto files](documentation/topics/proto-files.md)
- [DSL reference](documentation/dsls/DSL-AshGrpc.Domain.md)

## License

MIT.
