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
- [Interceptors and response meta](documentation/topics/interceptors-and-response-meta.md):
  your code around every call.
- [Bulk calls](documentation/topics/bulk-calls.md): many records in one call.
- [Streaming calls](documentation/topics/streaming-calls.md): many messages on
  one call.
- [Endpoint options](documentation/topics/endpoint-options.md): TLS, health
  checks, compression, server reflection and gRPC-Web with CORS.
- [Running in production](documentation/topics/production.md): behind a proxy.
- [How to test with AshGrpc](documentation/topics/testing.md): real calls
  against a real endpoint in a test.
- DSL reference: [AshGrpc.Resource](documentation/dsls/DSL-AshGrpc.Resource.md)
  and [AshGrpc.Domain](documentation/dsls/DSL-AshGrpc.Domain.md), every option
  of the two `grpc` blocks.

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
