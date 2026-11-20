# Getting started

This guide takes a blog from nothing to a gRPC call that is answered. It
assumes an Ash resource and a domain already exist.

## Install

With [Igniter](https://hexdocs.pm/igniter), one command does the install and
steps 3 and 4 below (it creates an authenticator that refuses every call, and
the endpoint, started on port 50051):

```sh
mix igniter.install ash_grpc@github:Undeadlol1/ash_grpc
```

Or by hand:

```elixir
def deps do
  [{:ash_grpc, github: "Undeadlol1/ash_grpc"}]
end
```

If your resources use policies, Ash needs a SAT solver such as
`:picosat_elixir` in your own dependencies.

## The shortest path

A resource with only the extension, a domain with two rpcs, an authenticator
and an endpoint (steps 3 and 4), and `config :ash_grpc, proto_output:` (step 5)
are all it takes. The rest of this guide shows what each step does.

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
        rpc :create_post
      end
    end
  end
end
```

The `resource` block holds the calls of one resource. The action defaults to the call's name; write it only when they differ. Here `:create_post` is
the name of the call and also of the action, so `rpc :create_post`
is enough. For one call, `rpc MyApp.Blog.Post, :create_post` on one line does the same.

`proto_output` is needed because field numbers are automatic: they are kept
in the generated `.proto`, which has to be committed and present at compile
time.

## 1. Choose the wire fields of a resource

Add `AshGrpc.Resource`. Every public attribute, calculation, aggregate and
relationship is sent, so nothing else is needed. Marking a field `public?: true`
puts it on the wire for every rpc of the resource; field policies still apply.

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshGrpc.Resource]

  attributes do
    uuid_primary_key :id, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    create_timestamp :inserted_at, public?: true
  end

  calculations do
    calculate :title_length, :integer, expr(string_length(title)), public?: true
  end

  actions do
    defaults [:read, :destroy, create: [:title], update: [:title]]
  end
end
```

Sensitive and private fields are left out. To leave out a public one, add
`grpc do hide_fields [:title_length] end`; to send only some, list them with
`grpc do fields [:id, :title] end`, where a listed field that cannot be sent
stops the build with a message naming it.

protobuf sends a field by number, not by name. AshGrpc numbers them for
you: 1, 2, 3... the first time, and after that it reads the numbers back from
the `.proto` file it generates (step 5), so a field keeps its number for as
long as clients use it. That is why you commit that file and keep it in the
build. `title: 2` in the list pins a number by hand. See
[Evolving your schema](evolving-your-schema.md).

A field whose attribute or calculation allows nil is `optional` on the wire.
Here `title_length` is: a calculation allows nil unless you say otherwise.

## 2. Choose the callable actions of a domain

```elixir
defmodule MyApp.Blog do
  use Ash.Domain, extensions: [AshGrpc.Domain]

  grpc do
    package "blog.v1"

    service "Posts" do
      rpc MyApp.Blog.Post, :list_posts, :read
      rpc MyApp.Blog.Post, :create_post, :create
      rpc MyApp.Blog.Post, :update_post, :update
    end
  end

  resources do
    resource MyApp.Blog.Post
  end
end
```

The request fields come from the action: an update gets the primary key (`id`),
which the server looks the record up with, then the attributes the action
accepts and its public arguments, then `clear_fields`. Numbers are chosen for
you. A list rpc can page, sort and filter without anything written. See
[Actions](actions.md) and
[Paging, sorting and filtering](pagination-sort-filter.md).

## 3. Write an authenticator

Every call needs one. It turns request headers into who is calling:

```elixir
defmodule MyAppWeb.GrpcAuthenticator do
  @behaviour AshGrpc.Authenticator

  @impl true
  def authenticate(%{"authorization" => "Bearer " <> token}) do
    case MyApp.Tokens.verify(token) do
      {:ok, user} -> {:ok, actor: user}
      {:error, _reason} -> {:error, :unauthenticated}
    end
  end

  def authenticate(_headers), do: {:error, :unauthenticated}
end
```

`MyApp.Tokens` stands for your own code. See [Authentication](authentication.md).

## 4. Define the endpoint and start it

```elixir
defmodule MyAppWeb.GrpcEndpoint do
  use AshGrpc.Endpoint,
    domains: [MyApp.Blog],
    authenticator: MyAppWeb.GrpcAuthenticator
end
```

Add it to your supervision tree. Start options are those of
`GRPC.Server.Supervisor`:

```elixir
children = [
  # ...
  {MyAppWeb.GrpcEndpoint, port: 50051}
]
```

At compile time the endpoint defines, for package `blog.v1`:

- `MyAppWeb.GrpcEndpoint.Blog.V1.Post`, the message of the resource;
- `...Blog.V1.ListPostsRequest`, `...ListPostsResponse` and so on, one pair per rpc;
- `...Blog.V1.Posts.Service`, `.Server` and `.Stub`.

An invalid `grpc` block stops the endpoint from compiling, with a message that
names the rpc or the field.

## 5. Generate the `.proto`

```sh
mix ash_grpc.gen.protos
```

The task reads its endpoint and directory from the configuration; the installer
sets it, by hand add:

```elixir
config :ash_grpc,
  endpoints: [MyAppWeb.GrpcEndpoint],
  proto_output: "priv/protos"
```

`proto_output` is also where the endpoint reads the numbers back from, so
commit the files and keep them in every build (in a Docker image, copy them
in before `mix compile`). `--endpoint` and `--output` override the task's
configuration. `mix ash.codegen` runs the task too,
and `mix ash.codegen --check` fails when the files are stale.

This writes `priv/protos/blog/v1.proto`, one file per package:

```proto
syntax = "proto3";

package blog.v1;

import "google/protobuf/struct.proto";
import "google/protobuf/timestamp.proto";

message Post {
  string id = 1;
  string title = 2;
  google.protobuf.Timestamp inserted_at = 3;
  optional int64 title_length = 4;
}

message ListPostsRequest {
  optional int64 limit = 1;
  optional int64 offset = 2;
  optional string after = 3;
  optional string before = 4;
  optional bool count = 5;
  optional string sort = 6;
  google.protobuf.Struct filter = 7;
}

message ListPostsResponse {
  repeated Post result = 1;
  bool has_more = 3;
  optional int64 count = 4;
  optional string first_keyset = 5;
  optional string last_keyset = 6;
}

message CreatePostRequest {
  optional string title = 1;
}

message CreatePostResponse {
  Post result = 1;
}

service Posts {
  rpc ListPosts(ListPostsRequest) returns (ListPostsResponse);
  rpc CreatePost(CreatePostRequest) returns (CreatePostResponse);
  rpc UpdatePost(UpdatePostRequest) returns (UpdatePostResponse);
}
```

The default `:read` of the Ash resource has pagination, so the list request
pages. (`UpdatePostRequest` and `UpdatePostResponse` are left out here.) Commit the
file. Clients in other languages build from it, and later runs compare against
it. See [Evolving your schema](evolving-your-schema.md).

## 6. Call it

From Elixir, use the generated stub. Request and response messages are
structs under the endpoint module:

```elixir
alias MyAppWeb.GrpcEndpoint.Blog.V1
alias MyAppWeb.GrpcEndpoint.Blog.V1.Posts.Stub

{:ok, channel} = GRPC.Stub.connect("localhost:50051")
metadata = %{"authorization" => "Bearer my-token"}

{:ok, %V1.CreatePostResponse{result: post}} =
  Stub.create_post(channel, %V1.CreatePostRequest{title: "Hello"}, metadata: metadata)

post.title
#=> "Hello"

{:ok, %V1.ListPostsResponse{result: posts}} =
  Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: metadata)
```

The `metadata` option is how the client sends the headers your authenticator
reads. `timeout: 5_000` sets a deadline in milliseconds; see [Actions](actions.md).

A call that fails returns `{:error, %GRPC.RPCError{}}`. For example, a create
without a title is `INVALID_ARGUMENT` naming the `title` field. See [Errors](errors.md).

## Next

- [Actions](actions.md) shows what each action kind puts in its request, and how `args` changes it.
- [Generating clients](generating-clients.md) builds Dart, Go, TypeScript and Python clients from the `.proto`.
- [Testing](testing.md) shows how to test an endpoint over a real socket.
