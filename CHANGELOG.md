# Changelog

## Unreleased

- Subscription responses have `optional uint32 position = 4`: the zero-based index the record has in the read action's sorted, filtered result when it was sent (snapshot messages carry 0..n-1). A change now reads the whole list instead of only the changed key, finds the record's index, and sends just that record. A client removes any copy of the record and inserts it at `min(position, length)`. `removed` messages leave `position` unset.

- `domains:` of `use AshGrpc.Endpoint` may be any expression that evaluates to a list at compile time (for example a function that discovers the app's domains), not only a literal list.

- `INVALID_ARGUMENT` adds one `google.rpc.ErrorInfo` detail per field violation after the `BadRequest`: `reason` is the Ash error's code (module name in snake_case, e.g. `required`), `domain` is `ash`, `metadata["field"]` is the field path. Details are no longer a single-element list.

- Reflection lists `grpc.health.v1.Health` when `health: true` is also on, so `grpcurl ... grpc.health.v1.Health/Check` works without a `.proto` (it failed with "does not expose service"). Checked with `grpcurl` and a Dart `grpc` client (reflection, health, unary, client and two-way streaming, bulk, gzip).

- Client and bidirectional streaming: `streaming: :client` or `streaming: :bidirectional` on an `rpc` turns the request into a stream of the rpc's ordinary request message, each run as its own call of the action. `:bidirectional` answers every message at once with `<Rpc>Reply` (`index`, then `result` or a `google.rpc.Status` `error`); `:client` answers one `<Rpc>Summary` (`succeeded` and `failures` with index and error). `max_stream_failures` (default 100) caps a `:client` call; one more is `RESOURCE_EXHAUSTED`. See the Streaming calls guide.

- `compressors: [GRPC.Compressor.Gzip]` on `use AshGrpc.Endpoint` lets the generated servers accept compressed requests and answer with the same `grpc-encoding`. Default `[]` changes nothing. The health service is not covered.

- Bulk calls: `bulk?: true` on a create, update or destroy `rpc`, with `max_bulk_size` (default 100; more answers `INVALID_ARGUMENT` before anything runs). Bulk create takes `repeated <Rpc>Input inputs`; bulk update and destroy take `repeated ids` (a repeated key message for a composite primary key) plus the action's inputs once. They run `Ash.bulk_create`, `Ash.bulk_update` and `Ash.bulk_destroy` with `transaction: :all`, so one failed item fails the whole call, and its error path names the item (`inputs[2].title`). Ids that do not exist or that the caller may not read are absent from the result.

- `health: true` on `use AshGrpc.Endpoint` serves the standard `grpc.health.v1.Health` service: `Check` answers `SERVING` for an empty name and for every served service and `NOT_FOUND` otherwise, `Watch` sends the current status and stays open. No credentials needed, no extra dependency, default off.

- TLS is documented and tested: start the endpoint with `adapter_opts: [cred: GRPC.Credential.new(ssl: [certfile: ..., keyfile: ...])]`.

- Tuples with `fields` constraints are sent as their own nested message, one field per element in declared order, and arrive in Ash as a tuple. Arrays of arrays, at any depth, are sent as `repeated` wrapper messages named `<Parent><Field>Item`, each holding `repeated T values = 1`. Arrays with `nil_items?: true` and tuples without `fields` still stop the build.

- An authenticator may answer `{:error, {:unavailable, retry_after_ms}}`: the call fails with `UNAVAILABLE` and the standard trailer `grpc-retry-pushback-ms`, so a client knows when to try again. `{:error, :unavailable}` is unchanged.

- A violation inside a list names the item in brackets: `labels[1].text` (it was `labels.1.text`).

- `resource MyApp.Blog.Post do ... end` inside a `service` groups a resource's calls: `rpc :publish`, `rpc :create_post, :create`, `subscription :watch_posts, :read`. Inside the block `rpc` and `subscription` take no resource. It means the same as the one-line form, and the generated `.proto` is identical.

- `rpc` and `subscription` take the resource first, then the call name, then the action: `rpc MyApp.Blog.Post, :create_post, :create`. The action defaults to the call's name; write it only when they differ: `rpc MyApp.Blog.Post, :create_post` runs the action `:create_post`. Exact match only; with no such action the build stops and lists the resource's actions. The old order (`rpc :name, Resource, :action`) no longer compiles.

- Opt-in server reflection: `use AshGrpc.Endpoint, reflection: true` serves the v1 and v1alpha reflection services (via the optional `grpc_reflection` package) for every service of the endpoint, so `grpcurl` and Postman need no `.proto`. Calls are authenticated like any other. Default off; without the package the build stops with a hint.

- Defaults first. On an `rpc` over a read that returns many, `sort` and `filter` are request fields by default, and paging is on by default when the Ash read action has `pagination` (the default `:read` does), with exactly the keys the action allows; numbers are automatic. `sort: false`, `filter: false` and `page: false` turn them off; `page: [:limit, :offset]` picks keys; explicit numbers (`sort: 7`, `page: [limit: 2]`) still work. A `subscription` gets `sort` and `filter` by default and never paging. `clear_fields` is on by default for an rpc on an update action; `clear_fields: false` turns it off. A default field named like one of the rpc's inputs stops the build and names the opt-out. A resource with `AshGrpc.Resource` gets `AshGrpc.Notifier` added automatically, so `simple_notifiers: [AshGrpc.Notifier]` is no longer needed (a resource that lists it is notified once).

- An `rpc` or `subscription` no longer needs `args`. Omitted, the request holds what the Ash action takes: for an update or destroy the primary key, then the attributes a create, update or destroy accepts, then the public arguments (a read gets only its public arguments). Private arguments are left out, so is an optional input with no protobuf mapping; a required one stops the build and suggests `args`. `args` may list names (`[:id, :title]`, exactly those) or `name: number` pairs, or both; `args: []` is an empty request. Request numbers are chosen like resource field numbers: the committed `<Rpc>Request` message keeps them, a removed input is reserved, and automatic numbers go around explicit `page`, `sort`, `filter` and `clear_fields` numbers. An rpc with every number written renders exactly as before. A destroy may now name an attribute it accepts.

- A resource exposes every public field by default, as `ash_json_api` and `ash_graphql` do: `use Ash.Resource, extensions: [AshGrpc.Resource]` is enough and `fields` is optional. The message is the public attributes, calculations (not on embedded resources), aggregates and relationships, in that order, all numbered automatically. Left out silently: sensitive fields, calculations with a required argument, fields whose type has no protobuf mapping, relationships to a resource without the extension. New option `hide_fields` removes public fields (an unknown name, or use with `fields`, stops the build). `fields` stays an allowlist with the same checks. A resource without a `grpc` block is now exposed (it used to be ignored), so a related resource with the extension but no block is no longer reported as having no `grpc` block. `AshGrpc.Resource.Info.grpc_fields/1` returns the resolved list.

- `fields` may list names without numbers (`fields [:id, :title]`, or mixed: `[:id, :body, title: 7]`). Numbers are chosen when the endpoint compiles, from the committed `.proto` under `proto_output`: a field in the file keeps its number, a new one gets the next number above the highest ever used (skipping 19000-19999), and a removed one is reserved. Un-numbered fields need `proto_output` configured; the endpoint recompiles when its files change. Resources with every number written work as before.
- `AshGrpc.Proto.render/2` on an endpoint returns exactly the files it serves (`__ash_grpc__(:protos)`). `mix ash_grpc.gen.protos` skips files whose text is unchanged and prints each newly retired field. `AshGrpc.Resource.Info.grpc_field_names/1` lists field names.

- Types: scalars, `:atom` (as `string`), proto enums (an `Ash.Type.Enum` or `NewType` over one, named after the module; an atom with `one_of`, named `<Parent><FieldName>`; `<NAME>_UNSPECIFIED = 0` then the Ash values from 1 in `values/0` order; value descriptions as comments; a bad or clashing name stops the build), `:map` (`google.protobuf.Struct`), arrays (`repeated`), embedded resources with a `grpc` block, typed structs, maps, keywords and structs with `fields` constraints (nested messages numbered in declaration order, also as arrays) and `Ash.Type.Union` (a nested message with one `oneof value`, a member per union type; a member that is an array is rejected). `:term` stops the build. Request strings and Structs go through Ash casting; a violation inside a nested value names its path (`labels[1].text`). Two different messages with one name stop the build.
- `fields` may name public aggregates, loaded like calculations and typed by Ash.
- `fields` may name public relationships: a message of the destination (which needs its own `grpc` block), `repeated` when to-many, absent when nil or not loaded; messages may recurse. `load:` on an `rpc` or `subscription` (what `Ash.Query.load/2` takes) says which are loaded, as the caller, for reads, create, update, destroy and generic results, and every subscription snapshot and change; a relationship the caller may not read is sent absent.
- Generic actions may return the resource, an array of it, any mappable type (scalars, enums, maps and structs with `fields` as a `<RpcName>Result` message, arrays as `repeated`) or nothing (an empty response). An unmappable return type stops the build.
- Paging, sorting and filtering, opt-in per rpc on a read that returns many: `page: [limit:, offset:, after:, before:, count:]` adds those request fields and gives the response `bool has_more = 3`, `optional int64 count = 4`, `optional string first_keyset = 5` and `optional string last_keyset = 6` as the keys allow; `sort: <number>` adds `optional string sort` and `filter: <number>` adds `google.protobuf.Struct filter`. A read that requires or defaults to pagination needs paging on the rpc (now the default).
- Subscriptions: `subscription Resource, :name, :read_action` is a server-streaming rpc that sends the current records and then each change, with `bool removed = 2` and `bool synced = 3`. Resources need `AshGrpc.Notifier`, which `AshGrpc.Resource` adds. Every change is re-read with the caller as actor. The `:ash_grpc` application starts a `:pg` scope.
- `cors: [allow_origin: ...]` on `use AshGrpc.Endpoint` lets browsers call over gRPC-Web.
- `clear_fields` on an `rpc` (a number pins it) adds `repeated string clear_fields`; each name reaches the action as `nil`.
- `response_meta: true` on `AshGrpc.Endpoint` adds `optional string meta = 2;` to every response; interceptors fill it with `AshGrpc.Endpoint.put_response_meta/2`. Adds the `jason` dependency.
- `interceptors:` on `AshGrpc.Endpoint`; authentication runs before them and `AshGrpc.Authenticator.fetch_opts/1` hands them its answer.
- `reserved` and `deprecated` in the resource and rpc DSL, rendered as protobuf `reserved`, `[deprecated = true]` and `option deprecated = true;`.
- `AshGrpc.Proto.Compatibility`; `mix ash_grpc.gen.protos` refuses breaking changes unless `--allow-breaking`, and `--check` also fails on a `.proto` the endpoint no longer renders.
- Fields that are not `public?: true`, or are `sensitive?`, are rejected at compile time. A field a field policy can hide (Ash expands `:*` to every non-key field) is `optional` in the schema and is sent unset when hidden, so one hidden field never fails a call.
- Errors: field violation descriptions are the error's own message; only invalid-class errors are described to clients, and an invalid error wrapping any other class is `INTERNAL`.
- A calculation with a required argument (not nil-allowing, no default) cannot be a field; the build stops naming it.
- `read_action:` on an update or destroy rpc picks the read action that finds the record (default: the primary read action). An update or destroy on a resource with neither stops the build.
- A read rpc that lists every primary key field in `args` answers one record (`NOT_FOUND` when missing), filtered by that key.
- `proto_message` is optional: it defaults to the last segment of the resource module.
- `description`s of resources, attributes, calculations, action arguments and actions are rendered as `//` comment lines in the `.proto`; the compatibility check ignores comment lines.
- Primary keys are cast with their constraints; an empty key is `INVALID_ARGUMENT`. The client deadline bounds the action, the record lookup and the result load.
- Documentation: README, getting-started tutorial, guides, generated DSL references, `usage-rules.md`.

## 0.1.0

- `AshGrpc.Resource` and `AshGrpc.Domain` DSL; invalid blocks stop the build.
- `AshGrpc.Endpoint` derives messages, services, servers and stubs.
- `AshGrpc.Authenticator` behaviour; errors mapped to gRPC statuses.
- `mix ash_grpc.gen.protos` with `--check`.
