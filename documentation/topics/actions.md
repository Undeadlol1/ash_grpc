# Actions

An `rpc` makes one Ash action callable:

```elixir
rpc MyApp.Blog.Post, :update_post, :update
```

The rpc name is camelized for the protobuf name: `update_post` becomes
`UpdatePost(UpdatePostRequest) returns (UpdatePostResponse)`. The response
message always holds `result = 1`: the resource message, `repeated` for a read
that is not `get? true`. Two rpcs on one resource share the resource message.

When a resource has several calls, group them; inside `resource`, `rpc` and
`subscription` do not name the resource again:

```elixir
resource MyApp.Blog.Post do
  rpc :update_post
  rpc :list_posts, :read
end
```

The action defaults to the call's name; write it only when they differ.

```elixir
rpc MyApp.Blog.Post, :update_post
rpc MyApp.Blog.Post, :list_posts, :read
```

The first runs the action `:update_post`. The name must match exactly; no
suffix or prefix is dropped. With no action of that name the build stops and
lists the resource's actions. The same goes for a `subscription` and its read
action.

## The request

Leave `args` out and the request holds what the action takes, in this order:

- for an update or destroy, the primary key;
- for a create, update or destroy, the attributes the action accepts
  (`accept`), in that order, leaving out private ones;
- the action's public arguments, in declaration order.

A read gets only its public arguments (no primary key; a lookup by key is
`args: [:id]`). A private argument is never included. An optional input whose
type has no protobuf mapping is left out; a required one stops the build,
naming the rpc and the input, until you list the inputs yourself.

Give `args` to choose the fields. `args: [:id, :title]` is exactly these two,
numbered automatically the way resource fields are: the committed `.proto`'s
`<Rpc>Request` message keeps each number, a removed input's number is
reserved, and `reserved:` on the rpc still works. `args: [id: 1, title: 2]`
pins the numbers, and the two forms mix (`[:id, title: 7]`). `args: []` is a
request with no fields. Automatic numbers go around every number you wrote,
including `page`, `sort`, `filter` and `clear_fields`.

A name written in `args` must be one of:

- an argument of the action;
- for a create, update or destroy, an attribute the action accepts;
- for an update or destroy, an attribute of the primary key.

Anything else stops the build. So does a type with no protobuf mapping (see
[Types](types.md)), a repeated name or number, or a number in the rpc's
`reserved`.

Every request scalar is `optional` on the wire. A field the client leaves
out is left out of the action input, so Ash reports a missing required
argument as `INVALID_ARGUMENT` naming it.

### Setting a value to nil

An unset field means "not sent", never nil. To let a client set a value to
nil, use `clear_fields`. It is on by default for an rpc on an update action:

```elixir
rpc MyApp.Blog.Post, :update_post, :update
```

The request gains `repeated string clear_fields`, numbered after the inputs.
`clear_fields: false` leaves it out, `clear_fields: true` adds it to any other
rpc, and a number (`clear_fields: 4`) pins its field number. Each name the client
lists there reaches the action as `nil`, so `clear_fields: ["body"]` empties
the body. Ash decides whether nil is allowed: clearing a required attribute is
`INVALID_ARGUMENT` naming that attribute. A name that is not a request field, is a
primary key, or is also sent with a value is `INVALID_ARGUMENT` naming
`clear_fields`.

A value Ash cannot cast (a malformed uuid, date, decimal, or an enum number
the enum does not know) is `INVALID_ARGUMENT` naming the field. So is a timestamp
outside the range of dates.

Every call runs with `authorize?: true`, and with the actor, tenant and
context from the [authenticator](authentication.md). Nothing the client sends
in the request can change them.

## Action kinds

### Read, many

```elixir
rpc MyApp.Blog.Post, :list_posts, :read
```

`result` is `repeated`. The request holds the action's public arguments. The client can also page,
sort and filter: `sort` and `filter` are on by default, and so is paging when
the action has `pagination`. `sort: false`, `filter: false` and `page: false`
turn them off; see [Paging, sorting and filtering](pagination-sort-filter.md).
A read with no `pagination` answers every record as a list. A read that
requires pagination or has `paginate_by_default?: true` stops the build if you
turn paging off with `page: false`.

### Read, one

```elixir
rpc MyApp.Blog.Post, :get_post, :by_id, args: [id: 1]
```

For a read with `get? true`, `result` is a single message. No record is
`NOT_FOUND`. Here `id` is an argument of the read.

A plain read can also look up one record by primary key, as AshJsonApi's
`get :read` does. List every primary key field in `args`:

```elixir
rpc MyApp.Blog.Post, :get_post, :read, args: [id: 1]
```

`result` is a single message, filtered by that key on top of the action's own
filter, policies and tenant. No record is `NOT_FOUND`, an omitted key is
`INVALID_ARGUMENT`. Listing only part of a composite key stops the build.

### Create

```elixir
rpc MyApp.Blog.Post, :create_post, :create
```

The request holds the arguments and accepted attributes you list.

### Update

```elixir
rpc MyApp.Blog.Post, :update_post, :update
```

The request must hold the whole primary key (automatic unless you list `args`). The server first loads the record by
it, as the caller: with the caller's actor and tenant, and with policies. A
record that does not exist, or one the caller may not read, is `NOT_FOUND`.
The other fields go to the action as input, so only the fields the client
sent change. A missing primary key is `INVALID_ARGUMENT`.

If the primary key attribute is also an argument of the action, it still
looks the record up and is also passed as that argument.

The record is found with the resource's primary read action. The resource
must have one, or the build stops. To use another read action (say, one that
hides soft-deleted records), name it:

```elixir
rpc MyApp.Blog.Post, :update_post, :update, read_action: :visible
```

`read_action` works on update and destroy rpcs only.

### Destroy

```elixir
rpc MyApp.Blog.Post, :delete_post, :destroy
```

Looked up like an update. `result` is the destroyed record, with its
calculation fields computed before the delete.

### Generic actions

```elixir
rpc MyApp.Blog.Post, :publish_post, :publish, args: [:id]
```

The request holds the action's arguments. What the action returns decides the
response:

| `returns` | response |
|---|---|
| the resource (`:struct` with `instance_of:` it) | `Post result`; a `nil` result is `NOT_FOUND` |
| `{:array, :struct}` with `items: [instance_of:` the resource`]` | `repeated Post result` |
| any type with a [mapping](types.md) | `result` of that type, `optional` when the action has `allow_nil? true`; a `nil` result is sent unset |
| an array of such a type | `repeated` result |
| a map, keyword or struct with `fields` | a message named `<RpcName>Result` (`Digest` returns `DigestResult`) |
| nothing | an empty response message |

```elixir
action :publish, :struct do
  constraints instance_of: __MODULE__
  argument :id, :uuid, allow_nil?: false

  run fn input, context -> ... end
end

action :word_count, :integer do
  argument :text, :string, allow_nil?: false

  run fn input, _context -> ... end
end
```

A return type with no mapping stops the build, naming the action and the
reason. Calculations are loaded only for results that are the resource.

## Calculations and aggregates

A field that is a calculation or an aggregate is loaded after a read, create,
update or generic action. One the action already set on the record is not
computed again. The loads run as the caller, like the action.

An aggregate is typed by Ash (`count` is `int64`, `sum` of an integer is
`int64`, `exists` is `bool`, `list` is `repeated`). It is `optional` when it can
be nil: every kind but `count`, `exists` and `list`, unless it has a `default`.

## Relationships

A public relationship is a field like any other (with an allowlist:
`fields [:id, :title, :author, :comments]`).
A `belongs_to` or `has_one` is a message field of the destination resource's
message; a `has_many` or `many_to_many` is `repeated` of it. A message field
has presence, so it is absent when the relationship is nil or not loaded. The
destination must use `AshGrpc.Resource` with its own `grpc` block, and a private
relationship is rejected. Messages may refer to each other in a cycle
(`Post.author`, `User.posts`); the `.proto` is valid.

Loading is decided by the server, per rpc or subscription, with `load:`, which
takes what `Ash.Query.load/2` takes:

```elixir
rpc MyApp.Blog.Post, :list_posts, :read, load: [:author, comments: [:author]]
```

Every name must be a relationship that is also a field of the message at that
depth, or the build stops. The relationships are loaded after the action, as the
caller (actor and tenant), so the related resource's read policies apply. This
holds for reads, the record a create, update, destroy or generic action returns,
a read by primary key, and each snapshot and change of a subscription. A
relationship that is not in `load`, or that the caller may not read, is sent
absent (empty for a to-many one) and never fails the call.

A loaded record carries the destination's own scalar fields, calculations and
aggregates, loaded with it. Its relationship fields are filled only as deep as
`load` says; the rest are absent.

Relationship fields never appear in requests. Manage them the Ash way, with an
action argument and `manage_relationship`:

```elixir
create :create_with_comments do
  accept [:title]
  argument :comments, {:array, :map}
  change manage_relationship(:comments, type: :create)
end
```

`rpc Post, :create_post, :create_with_comments, args: [title: 1, comments: 2]`
then takes `repeated google.protobuf.Struct comments`.

## Upserts and bulk calls

An upsert is an Ash feature of the create action (`upsert? true`, with
`upsert_identity`), so it works through the rpc of that action. There are no
bulk rpcs: call the action once per record, or write a generic action that
takes an array argument and give it an rpc.

## Deadlines

A client deadline (`timeout:` on the stub call, sent as `grpc-timeout`) becomes
the Ash `timeout`. When it passes, the call ends with `DEADLINE_EXCEEDED`.

```elixir
Stub.list_posts(channel, %V1.ListPostsRequest{}, metadata: metadata, timeout: 2_000)
```

The remaining time of the deadline is the Ash `timeout` of every step: the
action, the record lookup of an update or destroy, and the calculation loads
(a generic action also runs under it). Ash runs a step with a timeout in a task
of its own when the data layer supports async work and the step is not already
inside a transaction; otherwise it runs inline in the calling process. When the
action runs in a transaction, the data layer transaction gets the timeout
instead of a task. Process state set by an interceptor (the process dictionary,
a collector) is therefore not visible to a step that runs in a task.
See [Interceptors](interceptors-and-response-meta.md).
