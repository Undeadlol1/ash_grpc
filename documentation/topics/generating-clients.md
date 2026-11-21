# Generating clients

The `.proto` files are the contract. Write them with `mix ash_grpc.gen.protos`
(see [Getting started](getting-started.md)), commit them, and
generate a client in any language with that language's `protoc` plugin. Nothing
in the files is specific to Elixir.

The examples below use the `gadgets/v1.proto` that `mix ash_grpc.gen.protos`
writes into `priv/protos`. Run `protoc` from that directory so the import
paths match the package (`gadgets/v1.proto`).

## Where the imports come from

The files import `google/protobuf/struct.proto` for map fields. It ships with
`protoc` itself (the `include` directory of the release, or the `protobuf`
Homebrew/apt package), so `protoc` finds it without an `-I` flag. Dart, Go and
Python bring their own copy in their runtime packages; with Python's
`grpcio-tools` it is bundled.

A rpc with `streaming:` makes the file import `google/rpc/status.proto`, which
`protoc` does not ship. Take it from
[`googleapis/googleapis`](https://github.com/googleapis/googleapis) and add its
directory with another `-I`; the Dart `grpc` package ships a copy in
`lib/src/protos`. `grpcurl -import-path` needs the same extra path.

`google/rpc/error_details.proto` is never imported. An `INVALID_ARGUMENT` carries a
`google.rpc.BadRequest` in its status details (see [Errors](errors.md)); to read
it, use the generated type your gRPC library already ships (`errdetails` in Go,
`GrpcError.details` in Dart), or generate it from
[`googleapis/googleapis`](https://github.com/googleapis/googleapis) at
`google/rpc/error_details.proto`.

## Dart

```sh
dart pub global activate protoc_plugin
export PATH="$PATH:$HOME/.pub-cache/bin"

protoc -I . --dart_out=grpc:/path/to/app/lib/src/generated gadgets/v1.proto
```

The app needs `protobuf`, `fixnum` and `grpc` in its `pubspec.yaml`. The
`Struct` type comes from `package:protobuf/well_known_types`, so
`struct.proto` is not generated.

## Go

```sh
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

protoc -I . \
  --go_out=gen --go_opt=paths=source_relative \
  --go_opt=Mgadgets/v1.proto=example.com/app/gen/gadgets \
  --go-grpc_out=gen --go-grpc_opt=paths=source_relative \
  --go-grpc_opt=Mgadgets/v1.proto=example.com/app/gen/gadgets \
  gadgets/v1.proto
```

The files have no `go_package` option, so the `M` flags give the import path of
your module. Use your own module path in place of `example.com/app`.

## TypeScript

With [ts-proto](https://github.com/stephenh/ts-proto), which targets
`nice-grpc` for Node:

```sh
npm install --save-dev ts-proto
npm install nice-grpc

protoc -I . \
  --plugin=./node_modules/.bin/protoc-gen-ts_proto \
  --ts_proto_out=gen \
  --ts_proto_opt=outputServices=nice-grpc,outputServices=generic-definitions,useExactTypes=false \
  gadgets/v1.proto
```

A browser cannot speak plain gRPC; see [Calling from a browser](endpoint-options.md#calling-from-a-browser-grpc-web)
for the gRPC-Web side and the CORS option.

## Python

```sh
pip install grpcio-tools

python -m grpc_tools.protoc -I . \
  --python_out=gen --pyi_out=gen --grpc_python_out=gen \
  gadgets/v1.proto
```

## What the contract looks like from a client

Names below are the protobuf names; each language cases them its own way
(`clearFields` in Dart and TypeScript, `clear_fields` in Python).

### Enums

An Ash enum is a protobuf `enum` with a `<NAME>_UNSPECIFIED = 0` value first
(`MOOD_UNSPECIFIED`, `MOOD_CALM`...). Zero means "not sent". A client should
treat a number it does not know as an unknown value, not as an error: a newer
server may add values.

### Optional fields

A response field is `optional` when the attribute may be nil. Use the
language's presence check (`hasMood()` in Dart, `HasField("mood")` in Python, a
pointer in Go, `undefined` in ts-proto) to tell nil from the zero value. Every
scalar in a request is `optional`, so a client sends only what it means to set.

### Unions

An Ash union is a message with one `oneof value`. Read which member is set
(`whichValue()` in Dart, `WhichOneof("value")` in Python, a type switch in Go)
and read that member. Set exactly one member when sending.

### Clearing a value

An unset request field means "not sent", never nil. When the rpc has
`clear_fields`, the request has `repeated string clear_fields`; list the names
of the fields to set to nil there. See [Actions](actions.md).

### Paging

On a read with `page`, the request carries the `limit`, `offset`, `after`,
`before` and `count` fields the rpc listed, and the response carries
`has_more`, an optional `count`, and `first_keyset` / `last_keyset`. Offset
paging: ask for the next page with `offset + limit` while `has_more` is true.
Keyset paging: send the previous `last_keyset` as `after`. See
[Paging, sorting and filtering](pagination-sort-filter.md).

### Subscriptions

A subscription is a server-streaming rpc. Every message has `result`,
`removed`, `synced` and `position`. The client collects the records until
`synced` arrives, then applies each change by `position`; a map by primary key
is not enough. How, in [Subscriptions](subscriptions.md).

### Errors and deadlines

Failures arrive as gRPC statuses with a message; see [Errors](errors.md). Send
the token your authenticator expects as call metadata
(`authorization: Bearer ...`), and set a deadline on unary calls.
