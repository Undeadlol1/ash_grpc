# Changelog

## 0.1.0 (unreleased)

Expose Ash resources over gRPC.

### Resources and fields

- `AshGrpc.Resource` and `AshGrpc.Domain` DSL; an invalid block stops the build. `AshGrpc.Endpoint` derives messages, services, servers and stubs. `domains:` of `use AshGrpc.Endpoint` may be any expression that evaluates to a list at compile time.
- A resource exposes every public field by default: public attributes, calculations (not on embedded resources), aggregates and relationships, in that order, numbered automatically. Left out silently: sensitive fields, calculations with a required argument, fields whose type has no protobuf mapping, relationships to a resource without the extension. `hide_fields` removes public fields; `fields` is an allowlist. An unknown name, or `hide_fields` together with `fields`, stops the build. A field that is not `public?: true`, or is `sensitive?`, is rejected. A resource without a `grpc` block is exposed. `AshGrpc.Resource.Info.grpc_fields/1` returns the resolved list and `grpc_field_names/1` lists the names.
- `fields` may list names without numbers (`[:id, :title]`, or mixed: `[:id, :body, title: 7]`). Numbers come from the committed `.proto` under `proto_output`: a field in the file keeps its number, a new one gets the next number above the highest ever used (skipping 19000-19999), a removed one is reserved. Un-numbered fields need `proto_output`; the endpoint recompiles when its files change.
- `proto_message` is optional and defaults to the last segment of the resource module. `description`s of resources, attributes, calculations, action arguments and actions are rendered as `//` comments in the `.proto`.
- `reserved` and `deprecated` in the resource and rpc DSL render as protobuf `reserved`, `[deprecated = true]` and `option deprecated = true;`.
- A field a field policy can hide (Ash expands `:*` to every non-key field) is `optional` in the schema and is sent unset when hidden, so one hidden field never fails a call.
- `fields` may name public aggregates, loaded like calculations and typed by Ash, and public relationships: a message of the destination (which needs its own `grpc` block), `repeated` when to-many, absent when nil or not loaded; messages may recurse. `load:` on an `rpc` or `subscription` (what `Ash.Query.load/2` takes) says which are loaded, as the caller, for reads, create, update, destroy, generic results, and every subscription snapshot and change. A relationship the caller may not read is sent absent.
- Types: scalars, `:atom` (as `string`), proto enums (an `Ash.Type.Enum` or `NewType` over one, named after the module; an atom with `one_of`, named `<Parent><FieldName>`; `<NAME>_UNSPECIFIED = 0` then the Ash values from 1 in `values/0` order; value descriptions as comments; a bad or clashing name stops the build), `:map` (`google.protobuf.Struct`), arrays (`repeated`), embedded resources with a `grpc` block, typed structs, maps, keywords and structs with `fields` constraints (nested messages numbered in declaration order, also as arrays), and `Ash.Type.Union` (a nested message with one `oneof value`, a member per union type; a member that is an array is rejected). Tuples with `fields` constraints are a nested message, one field per element in declared order, and arrive in Ash as a tuple. Arrays of arrays, at any depth, are `repeated` wrapper messages named `<Parent><Field>Item`, each holding `repeated T values = 1`. `:term`, arrays with `nil_items?: true` and tuples without `fields` stop the build. Two different messages with one name stop the build. Request strings and Structs go through Ash casting; a violation inside a nested value names its path (`labels[1].text`).
- Primary keys are cast with their constraints; an empty key is `INVALID_ARGUMENT`. Primary keys of any wire type work, including timestamps and enums: the key is decoded from its wire type before the lookup.
- A calculation with a required argument (not nil-allowing, no default) cannot be a field; the build stops naming it.
- `AshGrpc.Notifier` is added to a resource with `AshGrpc.Resource` automatically; a resource that lists it too is notified once.

### Calls

- `rpc` and `subscription` take the resource first, then the call name, then the action: `rpc MyApp.Blog.Post, :create_post, :create`. The action defaults to the call's name. Exact match only; with no such action the build stops and lists the resource's actions.
- `resource MyApp.Blog.Post do ... end` inside a `service` groups a resource's calls: `rpc :publish`, `rpc :create_post, :create`, `subscription :watch_posts, :read`. Inside the block `rpc` and `subscription` take no resource. The generated `.proto` is identical to the one-line form.
- `args` is optional. Omitted, the request holds what the Ash action takes: for an update or destroy the primary key, then the attributes a create, update or destroy accepts, then the public arguments (a read gets only its public arguments). Private arguments are left out, so is an optional input with no protobuf mapping; a required one stops the build and suggests `args`. `args` may list names (`[:id, :title]`, exactly those), `name: number` pairs, or both; `args: []` is an empty request. The committed `<Rpc>Request` message keeps request numbers, a removed input is reserved, and automatic numbers go around explicit `page`, `sort`, `filter` and `clear_fields` numbers. A destroy may name an attribute it accepts.
- Generic actions may return the resource, an array of it, any mappable type (scalars, enums, maps and structs with `fields` as a `<RpcName>Result` message, arrays as `repeated`) or nothing (an empty response). An unmappable return type stops the build.
- `clear_fields` adds `repeated string clear_fields` to the request; each name reaches the action as `nil`. It is on by default for an rpc on an update action; `clear_fields: false` turns it off, a number pins it.
- `read_action:` on an update or destroy rpc picks the read action that finds the record (default: the primary read action). An update or destroy on a resource with neither stops the build.
- A read rpc that lists every primary key field in `args` answers one record (`NOT_FOUND` when missing), filtered by that key.
- The client deadline bounds the action, the record lookup and the result load.
- `response_meta: true` on `use AshGrpc.Endpoint` adds `optional string meta = 2;` to every response; interceptors fill it with `AshGrpc.Endpoint.put_response_meta/2`. It uses the `jason` dependency.
- `interceptors:` on `use AshGrpc.Endpoint`; authentication runs before them and `AshGrpc.Authenticator.fetch_opts/1` hands them its answer.

### Paging, sorting and filtering

- On an `rpc` over a read that returns many, `sort` and `filter` are request fields by default, and paging is on by default when the Ash read action has `pagination` (the default `:read` does), with exactly the keys the action allows; numbers are automatic. `sort: false`, `filter: false` and `page: false` turn them off; `page: [:limit, :offset]` picks keys; explicit numbers (`sort: 7`, `page: [limit: 2]`) work. A default field named like one of the rpc's inputs stops the build and names the opt-out.
- `page: [limit:, offset:, after:, before:, count:]` adds those request fields and gives the response `bool has_more = 3`, `optional int64 count = 4`, `optional string first_keyset = 5` and `optional string last_keyset = 6` as the keys allow. `sort` adds `optional string sort`; `filter` adds `google.protobuf.Struct filter`. A read that requires or defaults to pagination needs paging on the rpc.
- Sort and filter accept only fields the rpc sends; any other field answers `INVALID_ARGUMENT`.

### Bulk calls

- `bulk?: true` on a create, update or destroy `rpc`, with `max_bulk_size` (default 100; more answers `INVALID_ARGUMENT` before anything runs). Bulk create takes `repeated <Rpc>Input inputs`; bulk update and destroy take `repeated ids` (a repeated key message for a composite primary key) plus the action's inputs once. They run `Ash.bulk_create`, `Ash.bulk_update` and `Ash.bulk_destroy` with `transaction: :all`, so one failed item fails the whole call, and its error path names the item (`inputs[2].title`). Ids that do not exist or that the caller may not read are absent from the result.
- Bulk rpcs notify subscriptions: open subscriptions on the resource receive each created, updated or destroyed record.

### Streaming calls

- `streaming: :client` or `streaming: :bidirectional` on an `rpc` turns the request into a stream of the rpc's ordinary request message, each run as its own call of the action. `:bidirectional` answers every message at once with `<Rpc>Reply` (`index`, then `result` or a `google.rpc.Status` `error`); `:client` answers one `<Rpc>Summary` (`succeeded` and `failures` with index and error). `max_stream_failures` (default 100) caps a `:client` call; one more failure is `RESOURCE_EXHAUSTED`.

### Subscriptions

- `subscription Resource, :name, :read_action` is a server-streaming rpc that sends the current records and then each change, with `bool removed = 2` and `bool synced = 3`. It gets `sort` and `filter` by default and never paging. Every change is re-read with the caller as actor. The `:ash_grpc` application starts a `:pg` scope.
- Responses have `optional uint32 position = 4`: the zero-based index of the record in the read action's sorted, filtered result when it was sent (snapshot messages carry 0..n-1). A change reads the whole list, finds the record's index and sends just that record. A client removes any copy of the record and inserts it at `min(position, length)`. `removed` messages leave `position` unset.
- `max_subscriptions` on `use AshGrpc.Endpoint` caps open subscriptions (default 1000); one more is `RESOURCE_EXHAUSTED`.

### Authentication

- `AshGrpc.Authenticator` behaviour; its answer is the actor and context of the call. Authentication runs before interceptors.
- An authenticator may answer `{:error, {:unavailable, retry_after_ms}}`: the call fails with `UNAVAILABLE` and the standard trailer `grpc-retry-pushback-ms`, so a client knows when to try again. `{:error, :unavailable}` fails with `UNAVAILABLE` without the trailer.

### Errors

- Ash errors are mapped to gRPC statuses. Field violation descriptions are the error's own message; only invalid-class errors are described to clients, and an invalid error wrapping any other class is `INTERNAL`. When a call has both a forbidden and an invalid error, the forbidden one wins, in any order.
- `INVALID_ARGUMENT` carries a `google.rpc.BadRequest` detail, then one `google.rpc.ErrorInfo` detail per field violation: `reason` is the Ash error's code (module name in snake_case, e.g. `required`), `domain` is `ash`, `metadata["field"]` is the field path.
- A violation inside a list names the item in brackets: `labels[1].text`.

### Health, reflection, gRPC-web and compression

- `health: true` on `use AshGrpc.Endpoint` serves the standard `grpc.health.v1.Health` service: `Check` answers `SERVING` for an empty name and for every served service and `NOT_FOUND` otherwise, `Watch` sends the current status and stays open. No credentials needed, no extra dependency, default off.
- `reflection: true` serves the v1 and v1alpha reflection services (via the optional `grpc_reflection` package) for every service of the endpoint, so `grpcurl` and Postman need no `.proto`. Calls are authenticated like any other. Default off; without the package the build stops with a hint. With `health: true` the health service is listed too.
- `cors: [allow_origin: ...]` lets browsers call over gRPC-Web.
- `compressors: [GRPC.Compressor.Gzip]` lets the generated servers accept compressed requests and answer with the same `grpc-encoding`. Default `[]`. The health service is not covered.
- TLS: start the endpoint with `adapter_opts: [cred: GRPC.Credential.new(ssl: [certfile: ..., keyfile: ...])]`.

### Tools

- `mix ash_grpc.gen.protos` writes the `.proto` files, skips files whose text is unchanged, prints each newly retired field, and refuses breaking changes unless `--allow-breaking`. `--check` also fails on a `.proto` the endpoint no longer renders. `AshGrpc.Proto.render/2` returns exactly the files the endpoint serves (`__ash_grpc__(:protos)`).
- `AshGrpc.Proto.Compatibility` compares two `.proto` versions and ignores comment lines.
- Documentation: README, getting-started tutorial, guides, generated DSL references, `usage-rules.md`.
