# Rules for working with AshGrpc

AshGrpc exposes Ash actions over gRPC. The protobuf messages, service, server,
client stub and `.proto` files are derived from two DSL blocks. Read these
rules before writing code that uses it.

## Setup

- Add `{:ash_grpc, github: "Undeadlol1/ash_grpc"}` to deps. If resources use policies, the
  application also needs a SAT solver such as `:picosat_elixir`.
- Resource: `extensions: [AshGrpc.Resource]`. It sends every public field, so
  no `grpc` block is needed. The message is named after the module's last
  segment unless `proto_message` says otherwise.
- Domain: `extensions: [AshGrpc.Domain]` and a `grpc` block with `package` and
  one or more `service` blocks holding `rpc` entries.
- Endpoint: `use AshGrpc.Endpoint, domains: [...], authenticator: Mod`. Start
  it with `{MyAppWeb.GrpcEndpoint, port: 50051}` in the supervision tree.
- The messages, services, server and stub are generated under the endpoint
  module and the package: `MyAppWeb.GrpcEndpoint.Blog.V1.Posts.Stub`. Do not
  define them by hand.

## Resource and domain

- Group a resource's calls: `resource Resource do rpc :name; rpc :other, :action;
  subscription :watch, :read end` inside a `service`. Inside, `rpc` and
  `subscription` take no resource (writing it is a compile error); everything
  else is the same as the one-line form, and the proto is identical.
- `rpc Resource, :name` runs the action named exactly `:name`; write
  `rpc Resource, :name, :action` only when they differ. Resource first. A
  missing action fails the build and lists the resource's actions. The same
  goes for `subscription`.

- Public attributes, calculations, aggregates and relationships are sent by
  default (in that order). `public?: true` puts a field on the wire for every
  rpc of the resource; field policies still apply. Sensitive fields,
  calculations with a required argument, unmappable types and relationships to
  a resource without the extension are left out silently. `hide_fields [:a]`
  removes public fields; `fields [...]` is an allowlist and cannot be combined
  with `hide_fields`.
- List fields without numbers: `fields [:id, :title]`. The library numbers
  them and keeps the numbers in the committed `.proto` under `proto_output`,
  which must be configured, committed and present at compile time (copy it
  into a Docker image before `mix compile`). Reordering the list is safe.
- Write a number only to pin one (`[:id, headline: 2]` renames `title = 2`).
  Never change or reuse a written number. A resource with every number written
  (`fields id: 1, title: 2`) keeps the strict rules: retire by hand.
- A field listed in `fields` must be `public?: true` and not `sensitive?`, or the build stops.
  This includes `uuid_primary_key :id, public?: true` and
  `create_timestamp :inserted_at, public?: true`.
- `fields` takes attributes, calculations, public aggregates and public
  relationships. A relationship is a message of the destination (which needs its
  own `grpc` block), `repeated` when to-many, and is sent only when the rpc or
  subscription lists it in `load: [:author, comments: [:author]]`; otherwise it
  is absent. Manage relationships through action arguments and
  `manage_relationship`, never through request fields. Types must be string,
  ci_string, uuid, uuid_v7, atom (sent as a string), an `Ash.Type.Enum` or atom with `one_of` (a proto `enum`),
  integer, float, boolean, utc_datetime, utc_datetime_usec, datetime, date,
  time, time_usec, naive_datetime, duration (ISO 8601 strings), decimal,
  binary (`bytes`), url_encoded_binary (base64 text) or map (sent as
  `google.protobuf.Struct`). `{:array, T}` of those is `repeated`. An embedded
  resource with its own `grpc` block, a typed struct, and a map, keyword or
  struct with `fields` constraints are nested messages; `fields` constraints
  are numbered in declaration order, so only add fields at the end. A union is a
  message with a `oneof` of its types, numbered in declaration order; a union
  member that is an array is rejected. Tuples with `fields` are a nested message; arrays of arrays are `repeated` wrapper messages (`<Parent><Field>Item` with `repeated T values = 1`). Terms, tuples without `fields` and arrays that allow nil items are rejected at compile time.
- An empty repeated request field means "not sent", never "set to empty". To
  set an array to nil, use `clear_fields`.
- Leave `args` out: an `rpc` or `subscription` takes its request fields from the
  action (update/destroy primary key, then accepted attributes, then public
  arguments; a read gets only its public arguments), numbered automatically and
  kept in the committed `.proto`. `args: [:id, :title]` restricts to those
  names, `args: [id: 1]` pins numbers, `args: []` sends none. An optional input
  with no protobuf mapping is left out; a required one stops the build.
  An update or destroy needs the whole primary key and the resource needs a
  primary read action to find the record with (or `read_action:` on the rpc).
- Every request scalar is `optional`. An omitted field is left out of the
  input, never read as nil. To let a client set a value to nil, use
  `clear_fields`, which an rpc on an update action has by default: the request
  gains `repeated string clear_fields`, and each name listed there reaches the
  action as `nil`. `clear_fields: false` turns it off; `clear_fields: true` adds
  it to another rpc.
- A read whose `args` list the whole primary key (`args: [:id]`) answers one record, like AshJsonApi's `get :read`; listing part of a composite key stops the build.
- Supported actions: read (one with `get? true`, or many), create, update,
  destroy, and generic actions returning the resource, any mappable type, an
  array of one, or nothing (an empty response).
- Paging, sorting and filtering are on by default on an rpc over a read that
  returns many, with nothing written: `sort` (`optional string sort`,
  `Ash.Query.sort_input/2` syntax), `filter` (`google.protobuf.Struct filter`,
  `Ash.Query.filter_input/2` map syntax) and, when the Ash read action has
  `pagination` (the default `:read` does), exactly the page keys it allows
  (`limit`, `offset`, `after`, `before`, `count`). A paged response gains
  `has_more = 3`, `count = 4`, `first_keyset = 5`, `last_keyset = 6` as the
  keys allow. Turn off with `sort: false`, `filter: false`, `page: false`;
  `page: [:limit, :offset]` picks keys; `sort: 7` and `page: [limit: 2]` pin
  numbers. A read that requires or defaults to pagination stops the build with
  `page: false`. A default field named like one of the rpc's inputs stops the
  build and names the opt-out. A client may sort and filter (at any depth,
  and through relationships) only by fields in the rpc's response message; any
  other field, even a public one, is `INVALID_ARGUMENT`, so `hide_fields`
  also hides a field from sort and filter probing.
- A union is rendered as a `oneof`. An `Ash.Type.Enum` or atom with `one_of` is a
  proto `enum`: append new values at the end of `values/0`, never reorder.
- Do not put identity in the request (no `user_id`, `tenant` field). Identity
  comes only from the authenticator.

## Streaming calls

- `streaming: :bidirectional` answers every message at once with `index` and `result` or
  `error` (`google.rpc.Status`). `streaming: :client` answers one summary: `succeeded` and
  `failures`. Each message runs the action once like a unary call; a refused message does
  not undo earlier ones. `max_stream_failures` (default 100, `:client` only): one more is
  `RESOURCE_EXHAUSTED`. Not with `bulk?`; `:client` needs a writing action.

## Subscriptions

- `subscription Resource, :name, :read_action` inside a `service` makes a
  server-streaming rpc: the current records, then each change. `AshGrpc.Resource`
  adds `AshGrpc.Notifier` to the resource itself: do not add `simple_notifiers`
  (it is harmless, and notifies once). The primary key must be sent, and the
  action must be a read that does not require or default to pagination. The
  build stops otherwise. `sort` and `filter` are on by default as on an rpc and
  apply to every re-read; there is never paging.
- Do not copy record data from notifications or send it yourself. Every change
  is re-read with the caller as actor, so policies and the action's filter
  decide what each subscriber sees.
- `synced = true` (no `result`) is sent once, right after the snapshot, also
  when it is empty. Clients collect records until it arrives, then show the
  list and apply later responses one by one.
- `removed = true` means the record left the caller's view; `result` holds only
  the primary key. A client must drop the record, not treat it as deleted for
  everyone.
- Do not promise delivery of missed changes: there is no resume cursor, a
  reconnect starts with a fresh snapshot, and a slow client has no backpressure.
- Writes only notify when they go through an Ash action; bulk actions need
  `notify?: true`. Multiple nodes need connected Erlang nodes.
- Clients should set a deadline. A subscription ends with `DEADLINE_EXCEEDED`
  when it passes.

## Authentication

- Implement the `authenticate/1` callback of `AshGrpc.Authenticator`. Headers are a map of
  lowercase string keys.
- Return `{:ok, actor: ..., tenant: ..., context: ...}`, `{:error, :unauthenticated}`
  or `{:error, :unavailable}`. Use `:unavailable` when the check could not be
  done, not when the credentials are wrong.
- Do not return anything else, and do not rely on raising: both end as
  `INTERNAL`.
- Authorization always runs. Write Ash policies; do not check permissions in
  an interceptor.

## Interceptors and response meta

- `interceptors: [Mod, {Mod, opts}]` on the endpoint; the first is outermost.
  They run after authentication; read its answer with
  `AshGrpc.Authenticator.fetch_opts/1`.
- Request metadata is `stream.http_request_headers`, keys lowercase.
- Do not put values that can grow in trailers (`GRPC.Server.set_trailers/2`):
  over 4 KB breaks the HTTP/2 connection. Use `response_meta: true` and
  `AshGrpc.Endpoint.put_response_meta(stream, fn -> %{...} end)` before
  `next`. Failed calls carry no meta.
- With a client deadline, the remaining time is the Ash `timeout` of the action,
  the record lookup and the loads. Ash runs such a step in a task when the data
  layer supports async work and it is not in a transaction (in a transaction
  the data layer gets the timeout); otherwise inline. Process state set by an
  interceptor is not visible to a step that runs in a task.

## Browsers

- `cors: [allow_origin: "https://app.example.com"]` on the endpoint lets browsers call over gRPC-Web; a preflight never reaches the authenticator.

## Errors

- Do not map errors yourself. Invalid input is `INVALID_ARGUMENT` with
  `google.rpc.BadRequest` field violations, forbidden is `PERMISSION_DENIED`,
  missing is `NOT_FOUND`, an expired deadline is `DEADLINE_EXCEEDED`, anything
  else is `INTERNAL` with a fixed message and a logged cause.
- Do not return exception text to clients.

## Evolving the schema

- Never change what a number means. Give a changed field a new number.
- To retire an un-numbered field, remove it from `fields`; regenerating
  reserves its number. With written numbers, also add its number to
  `reserved`. For an rpc request field use `reserved: [n]` on the `rpc`.
- To warn clients off a field, use `deprecated [:name]`; for an rpc,
  `deprecated: true`. It is still served.
- Generate the `.proto` with
  `mix ash_grpc.gen.protos --endpoint Mod --output priv/protos` and commit it.
  The task refuses breaking changes against the committed file.
- Do not pass `--allow-breaking` unless the user asked for a break.
- Run the same task with `--check` in CI to catch drift.

## Testing

- Test over a real socket: `start_supervised!({Endpoint, port: 0})`, then
  `:ranch.get_port(inspect(Endpoint))` and `GRPC.Stub.connect/1`. Send identity
  with `metadata: %{"authorization" => ...}`.
- Assert on `GRPC.Status` values, and decode details with
  `Google.Rpc.BadRequest`.
- Use `AshGrpc.Proto.render/1` and `AshGrpc.Proto.Compatibility.check/2` to test
  the `.proto` without writing files.

## Reflection

- `reflection: true` on the endpoint serves gRPC reflection for `grpcurl` and
  Postman. It needs `{:grpc_reflection, "~> 0.5"}` in deps and is off by
  default.
- Reflection calls are authenticated: send `-H 'authorization: ...'`. Keep it
  off in production unless exposing the schema is intended.

## Bulk calls, health, TLS and retry

- Many records in one call: `bulk?: true` on a create, update or destroy rpc.
  One failed item fails the whole call, `max_bulk_size` (default 100) caps the
  list, and missing or unreadable ids are absent from the result. Do not loop
  single calls from the client instead.
- `health: true` on the endpoint serves `grpc.health.v1.Health` without
  credentials. TLS is `adapter_opts: [cred: GRPC.Credential.new(ssl: [...])]`
  at start; the library has no TLS option of its own.
- `compressors: [GRPC.Compressor.Gzip]` on the endpoint accepts and answers
  gzip; the default `[]` refuses a call that asks for compression. Health is
  not covered.
- An authenticator that cannot decide right now answers
  `{:error, {:unavailable, retry_after_ms}}`; the client gets `UNAVAILABLE`
  and the trailer `grpc-retry-pushback-ms`.
