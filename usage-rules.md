# Rules for working with AshGrpc

AshGrpc serves Ash actions over gRPC. Read these rules before writing code
that uses it.

## Setup

- Add `{:ash_grpc, github: "Undeadlol1/ash_grpc"}` to deps. Add `{:phoenix_pubsub, "~> 2.1"}` and
  `{:phoenix, "~> 1.7"}` only if you use `AshGrpc.PubSubSource`.
- Add `extensions: [AshGrpc.Domain]` to the `use Ash.Domain` and declare routes
  in a `grpc do routes do service "/pkg.v1.Name" do ... end end end` block.
- Start `GRPC.Server.Supervisor` in your own supervision tree. AshGrpc does
  not start a server.

## Routes

- Route kinds: `unary`, `server_stream`, `client_stream`,
  `bidirectional_stream`. Each takes `(name, resource, action)`.
- Unary routes may omit mappers. Streaming routes always need
  `request_mapper` and `response_mapper`.
- A request mapper exposes `to_ash_input/1`; a response mapper exposes
  `to_response/1`. Return `{:ok, value}` or `{:error, error}`.
- Call the matching `AshGrpc.Transport.handle_*` function from the generated
  `GRPC.Server` module, and `unwrap_response/1` for unary and client streams.

## Security

- Never set `trust_request_metadata: true` on an endpoint reachable by
  untrusted clients. Use an `AshGrpc.Authenticator` instead.
- Build errors with `AshGrpc.ErrorMapper.to_rpc_error/1`; do not hand-build
  `GRPC.RPCError` for Ash failures.
- Use `AshGrpc.ListQuery` for client-supplied filter, sort and pagination.

## Config keys

- `config :ash_grpc, authenticator: Module`
- `config :ash_grpc, actor_resolver: Module`
