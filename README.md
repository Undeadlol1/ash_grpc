# AshGrpc

A gRPC API for [Ash](https://hexdocs.pm/ash) resources. A resource sends its
public fields; you name the actions. The messages, the server and the `.proto`
file are made for you.

## TL;DR

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource, domain: MyApp.Blog, extensions: [AshGrpc.Resource]
end

defmodule MyApp.Blog do
  use Ash.Domain, extensions: [AshGrpc.Domain]

  grpc do
    package "blog.v1"

    service "Posts" do
      resource MyApp.Blog.Post do
        rpc :list_posts, :read
        rpc :create_post, :create
      end
    end
  end
end
```

A resource with several calls goes in a `resource` block. For a single call
the one-line form is shorter: `rpc MyApp.Blog.Comment, :add_comment`. Both can
sit in the same service and mean the same thing.

The action defaults to the call's name; write it only when they differ.
`rpc :update_post` (in a `resource MyApp.Blog.Post` block) runs the action `:update_post` of the
resource. The name must match exactly; if there is no such action the build
stops and lists the resource's actions.

`mix ash_grpc.gen.protos` writes the file any gRPC client is generated from:

```proto
message Post {
  string id = 1;
  string title = 2;
  google.protobuf.Timestamp inserted_at = 3;
}

service Posts {
  rpc ListPosts(ListPostsRequest) returns (ListPostsResponse);
  rpc CreatePost(CreatePostRequest) returns (CreatePostResponse);
}
```

Every public attribute, calculation, aggregate and relationship of `Post` is a
field. A call runs the Ash action as the caller, with its policies. The
request of `ListPosts` can page, sort and filter, and `CreatePost` takes the
attributes the `:create` action accepts. Nothing else is written. That's it.

## Features

- **Nothing to keep in sync.** The server and the `.proto` come from the same
  two `grpc` blocks, so they cannot disagree.
- **Ash already knows most of it.** Types, enums and their values, nested
  objects, relationships, descriptions and required arguments are read from
  the resource. Field numbers are chosen for you and kept in the generated
  `.proto`.
- **Policies always run.** The caller comes from one place, your
  authenticator. A field hidden by a field policy is sent empty.
- **Lists the client can page, sort and filter.** On by default for a read that
  returns many; one word turns each off.
- **Live lists.** A read can be a stream: the current records first, then
  every change as it is saved. Nothing to set up on the resource.
- **Old clients keep working.** The generator refuses a change that would
  break an app that is already installed.
- **Mistakes stop the build.** A private field, a reused number or an unknown
  action is a compile error that names the thing to fix.

## Installation

With [Igniter](https://hexdocs.pm/igniter):

```sh
mix igniter.install ash_grpc@github:Undeadlol1/ash_grpc
```

It adds the package, an endpoint, an authenticator that refuses every call
until you fill it in, and the configuration. By hand, add the package:

```elixir
def deps do
  [
    {:ash_grpc, github: "Undeadlol1/ash_grpc"}
  ]
end
```

Then define the endpoint and start it:

```elixir
defmodule MyAppWeb.GrpcEndpoint do
  use AshGrpc.Endpoint,
    domains: [MyApp.Blog],
    authenticator: MyAppWeb.GrpcAuthenticator
end

# lib/my_app/application.ex
children = [
  # ...
  {MyAppWeb.GrpcEndpoint, port: 50051}
]
```

```elixir
# config/config.exs
config :ash_grpc,
  endpoints: [MyAppWeb.GrpcEndpoint],
  proto_output: "priv/protos"
```

## Usage

### Say who is calling

The authenticator is your code. It gets the request headers and returns the
actor. Every action of the call runs as that actor, with authorization on.

```elixir
defmodule MyAppWeb.GrpcAuthenticator do
  @behaviour AshGrpc.Authenticator

  @impl true
  def authenticate(%{"authorization" => "Bearer " <> token}) do
    case MyApp.Tokens.verify(token) do
      {:ok, user} -> {:ok, actor: user, tenant: user.org_id}
      {:error, _reason} -> {:error, :unauthenticated}
    end
  end

  def authenticate(_headers), do: {:error, :unauthenticated}
end
```

`MyApp.Tokens` stands for your own code. More in
[Authentication](documentation/topics/authentication.md).

### Pick the fields

Public fields are exposed by default, as in `ash_json_api` and `ash_graphql`:
every public attribute, calculation, aggregate and relationship is sent, in
that order. Marking a field `public?: true` therefore puts it on the wire for
every rpc of that resource. Field policies still apply to the caller. Private
fields are never sent. Left out without an error: sensitive fields,
calculations with a required argument, fields whose type has no protobuf
mapping, and relationships to a resource without `AshGrpc.Resource`.

To keep a public field off the wire, hide it:

```elixir
grpc do
  hide_fields [:internal_note]
end
```

To send only some fields, list them. `fields` is then an allowlist, and a
listed field that cannot be sent (private, sensitive, unmappable) stops the
build. It cannot be combined with `hide_fields`.

```elixir
grpc do
  fields [:id, :title, :status, :comment_count, :author]
end
```

protobuf knows a field by its number, so every field gets one. You do not
pick them: the first time, they are 1, 2, 3... in order. After that, the
generated `.proto` file remembers them. A field already in the file keeps
its number, a new field gets the next number after the highest one ever
used, and a field that stops being public or is hidden has its number
reserved. Reordering a `fields` list changes nothing. So commit the generated
file, and make sure it is there when the app compiles (in a Docker build, copy
`priv/protos` in before `mix compile`). This needs `proto_output` in the
config above.

To choose a number yourself, write it in `fields`: `fields [:id, :body, title: 7]`,
or `fields id: 1, title: 2` for all of them.

The protobuf type comes from the Ash type. An `Ash.Type.Enum` becomes a real
enum with the same values in the same order. An embedded resource becomes its
own message. A union becomes a message holding exactly one of its variants.
The full list is in [Types](documentation/topics/types.md).

### Call an action

The request fields come from the Ash action, as in `ash_json_api` and
`ash_graphql`, so there is nothing to list: for an update or a destroy the
primary key (it finds the record), then the attributes a create, update or
destroy accepts, then the action's public arguments. Numbers are chosen for
you and kept in the committed `.proto`.

```elixir
rpc MyApp.Blog.Post, :create_post, :create
rpc MyApp.Blog.Post, :update_post, :update
rpc MyApp.Blog.Post, :archive_post, :destroy
```

A read gets only its public arguments, so a lookup by key names it:
`rpc MyApp.Blog.Post, :get_post, :read, args: [:id]`. `args:` is only for
restricting or pinning: it narrows the request to exactly the names you list (`[:id, :title]`); `args: []` sends no
fields; `args: [id: 1, title: 2]` pins the numbers. An optional input whose
type has no protobuf mapping is left out; a required one stops the build.

An update rpc also gets `repeated string clear_fields`, which lets the client
set a value to empty; `clear_fields: false` leaves it out.

A read that names the whole primary key returns one record. A generic action
returns whatever it returns in Ash. More in
[Actions](documentation/topics/actions.md).

### Send related records

A relationship is a field like any other. Each call says on the server which
ones it loads:

```elixir
rpc MyApp.Blog.Post, :list_posts, :read, load: [:author, comments: [:author]]
```

One related record is a nested message, many are a list. They are read as the
caller, so one the caller may not see comes back empty.

### Page, sort and filter a list

On by default, with nothing written. On an `rpc` over a read that returns
many, the request gets `sort` and `filter`, and paging when the Ash read
action has `pagination` (Ash's default `:read` does): exactly the keys the
action allows, `limit`, `offset`, `after`, `before` and `count`.

```elixir
rpc MyApp.Blog.Post, :list_posts, :read
```

The client sends `limit: 20, sort: "-inserted_at"`, and the response says
`has_more`. To turn one off:

```elixir
rpc MyApp.Blog.Post, :list_posts, :read, sort: false, filter: false, page: false
```

`page: [:limit, :offset]` picks the keys. A number pins a field number
(`sort: 7`, `page: [limit: 2]`). More in
[Paging, sorting and filtering](documentation/topics/pagination-sort-filter.md).

### Watch a list live

Name a subscription. The resource needs nothing: `AshGrpc.Resource` adds the
notifier itself.

```elixir
subscription MyApp.Blog.Post, :watch_posts, :read
```

The client gets the records it may read, then a "you are up to date" marker,
then every change. A record it can no longer see is sent as removed. It takes
`sort` and `filter` like a list, and never paging. More in
[Subscriptions](documentation/topics/subscriptions.md).

### Generate the `.proto` and the clients

```sh
mix ash_grpc.gen.protos           # writes priv/protos/blog/v1.proto
mix ash_grpc.gen.protos --check   # in CI: fails when a file is stale
```

`mix ash.codegen` runs it too. Commit the files; they are the history the
compatibility check compares against. To turn them into Dart, Go, TypeScript
or Python code, see
[Generating clients](documentation/topics/generating-clients.md).

### Remove a field safely

Take it out of `fields`. Its number is retired for you: the next
`mix ash_grpc.gen.protos` writes `reserved 3;` into the file, prints which
field was retired, and no later field gets that number.

To rename a field and keep its number, pin the new name to the old number:
`fields [:id, headline: 2]`. The wire stays the same; the generator still
asks for `--allow-breaking`, because client code generated from the file
changes its names.

A resource whose fields all have numbers written by hand is strict instead:
retire the number yourself with `reserved [3]`, or the generator stops and
says what to add. To keep a field
served while telling clients to stop using it, use `deprecated [:title]`.
More in [Evolving your schema](documentation/topics/evolving-your-schema.md).

### Call it from Elixir

The endpoint also defines a client, which is what your tests use. A client that uses `GRPC.Stub.connect/2` needs `{:gun, "~> 2.4"}` in its own deps, because grpc made its HTTP client optional.

```elixir
alias MyAppWeb.GrpcEndpoint.Blog.V1
alias MyAppWeb.GrpcEndpoint.Blog.V1.Posts.Stub

{:ok, channel} = GRPC.Stub.connect("localhost:50051")
metadata = %{"authorization" => "Bearer " <> token}

{:ok, %{result: post}} =
  Stub.create_post(channel, %V1.CreatePostRequest{title: "Hello"}, metadata: metadata)

post.title  #=> "Hello"
```

Invalid input comes back as `INVALID_ARGUMENT` with the field that was wrong;
see [Errors](documentation/topics/errors.md).

### Call it without a `.proto` file

```elixir
use AshGrpc.Endpoint, domains: [MyApp.Blog], authenticator: MyApp.GrpcAuthenticator, reflection: true
```

```sh
grpcurl -plaintext -H 'authorization: Bearer TOKEN' localhost:50051 list
```

Needs `{:grpc_reflection, "~> 0.5"}` in your deps; see
[Server reflection](documentation/topics/reflection.md).

## Learn more

- [Getting started](documentation/tutorials/getting-started.md): from zero to
  a call answered.
- [Actions](documentation/topics/actions.md): how each kind of action is
  called, relationships, and setting a value to empty.
- [Types](documentation/topics/types.md): which Ash type becomes which
  protobuf type.
- [Authentication](documentation/topics/authentication.md): the
  authenticator and what reaches Ash.
- [Paging, sorting and filtering](documentation/topics/pagination-sort-filter.md):
  the options of a list call.
- [Subscriptions](documentation/topics/subscriptions.md): live records over a
  stream.
- [Errors](documentation/topics/errors.md): which Ash error becomes which
  gRPC status.
- [Evolving your schema](documentation/topics/evolving-your-schema.md):
  removing and renaming without breaking clients.
- [Generating clients](documentation/topics/generating-clients.md): Dart, Go,
  TypeScript and Python.
- [Calling from a browser](documentation/topics/browser-grpc-web.md): gRPC-Web
  and CORS.
- [Interceptors and response meta](documentation/topics/interceptors-and-response-meta.md):
  your code around every call.
- [Server reflection](documentation/topics/reflection.md): `grpcurl` and
  Postman without a `.proto`.
- [Bulk calls](documentation/topics/bulk-calls.md): many records in one call.
- [Health checks](documentation/topics/health.md): the standard health
  service for load balancers.
- [TLS](documentation/topics/tls.md): an encrypted endpoint.
- [Compression](documentation/topics/compression.md): gzip for requests and responses.
- [How to test with AshGrpc](documentation/topics/testing.md): real calls
  against a real endpoint in a test.
- DSL reference: [AshGrpc.Resource](documentation/dsls/DSL-AshGrpc.Resource.md)
  and [AshGrpc.Domain](documentation/dsls/DSL-AshGrpc.Domain.md), every option
  of the two `grpc` blocks.

## What is supported

- Read (one or many), create, update and destroy actions.
- The action of an `rpc` or `subscription` defaults to the call's name.
- Generic actions that return the resource, any mappable type, an array of one, or nothing.
- Every public field exposed by default; `hide_fields` or `fields` to narrow.
- Request fields taken from the Ash action; `args` to restrict them.
- Attributes, calculations and aggregates as message fields: scalars, arrays, maps, enums,
  embedded resources, typed structs, unions, tuples and arrays of arrays.
- Relationships as message fields, loaded per rpc with `load:` as the caller.
- Paging, sorting and filtering on reads that return many, on by default.
- Actor, tenant and context from an authenticator; authorization always runs.
- Interceptors, and an optional `meta` field on every response.
- Subscriptions: server-streaming rpcs that send the current records, then each change.
- Errors mapped to gRPC statuses, with field violations for invalid input.
- Calls from a browser over gRPC-Web, with CORS.
- Opt-in server reflection, so `grpcurl` and Postman work without a `.proto` file.
- Streaming calls: `streaming: :client` or `:bidirectional` sends many messages on one call,
  each run as its own action call, with the failures reported per message.
- Bulk calls: `bulk?: true` on a create, update or destroy rpc changes many records in one
  all-or-nothing call.
- The standard health service (`health: true`) and TLS.
- An authenticator can tell the client when to retry.
- `.proto` generation, with a guard against changes that break clients. Ash `description`s
  become `//` comments.

## What is not supported

`:term`, arrays that allow nil items.

Two things that may surprise you:

- **A duplicate is reported as invalid input.** A unique-constraint error
  answers `INVALID_ARGUMENT`, not `ALREADY_EXISTS`; see
  [Errors](documentation/topics/errors.md).
- **A relationship is loaded only when the call says so.** A relationship
  field without `load:` on the rpc is sent empty.

## For AI assistants

<details>
<summary>Instructions for coding agents (Claude Code, Cursor, Copilot, ...)</summary>
<p>
The file for agents is <a href="usage-rules.html"><code>usage-rules.md</code></a>.
It ships inside the package, so after <code>mix deps.get</code> it is at
<code>deps/ash_grpc/usage-rules.md</code>. Point your agent at that file.
If your project uses the
<a href="https://hexdocs.pm/usage_rules"><code>usage_rules</code></a>
package, add <code>:ash_grpc</code> to its list instead.
</p>
</details>

## License

MIT. See the `LICENSE` file.
