# Changelog

## 0.1.0

First release.

- `AshGrpc.Domain` Spark extension: `unary`, `server_stream`, `client_stream`
  and `bidirectional_stream` routes bound to Ash actions.
- Server-derived actors through `AshGrpc.Authenticator`; client `x-ash-*`
  metadata is rejected unless `trust_request_metadata: true`.
- `grpc-timeout` deadlines, Ash-to-gRPC error mapping with field details,
  list requests through `AshGrpc.ListQuery`.
- `AshGrpc.NotifierStream` and `AshGrpc.PubSubSource` for live updates.
- `mix ash_grpc.gen.protos` for `.proto` export.
