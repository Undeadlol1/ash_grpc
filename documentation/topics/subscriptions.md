# Subscriptions

A subscription is a server-streaming rpc over a read action. The client opens
the call, gets the records it can read right now, and then gets every change
to them until it hangs up or its deadline passes.

## Setting it up

Name the subscription in the domain. The resource needs nothing beyond
`AshGrpc.Resource`, which adds `AshGrpc.Notifier` to it so that its writes
are announced.

```elixir
defmodule MyApp.Blog.Post do
  use Ash.Resource, domain: MyApp.Blog, extensions: [AshGrpc.Resource]
end

defmodule MyApp.Blog do
  use Ash.Domain, extensions: [AshGrpc.Domain]

  grpc do
    package "blog.v1"

    service "Posts" do
      rpc MyApp.Blog.Post, :list_posts, :read
      subscription MyApp.Blog.Post, :watch_posts, :read
    end
  end
end
```

Inside a `resource MyApp.Blog.Post do ... end` block write
`subscription :watch_posts, :read` without the resource.

A resource that already lists `AshGrpc.Notifier` in `notifiers` or
`simple_notifiers` is notified once, not twice. The build stops if the action
is not a read, or if the primary key is not among the sent fields. A read that
requires or defaults to pagination is rejected: a subscription sends every
record, so it never has paging fields. `sort` and `filter` are in the request
by default (`sort: false` and `filter: false` turn them off) and apply to
every re-read; see [Paging, sorting and filtering](pagination-sort-filter.md).

## The generated proto

```proto
rpc WatchPosts(WatchPostsRequest) returns (stream WatchPostsResponse);

message WatchPostsResponse {
  Post result = 1;
  bool removed = 2;
  bool synced = 3;
  optional uint32 position = 4;
}
```

The request fields come from the read action as for an `rpc`; `args` restricts
them, and each must be an argument of the read action. `subscription Note, :watch_matching, :matching, args: [word: 1]` gives
the request a `word` field that is passed to the `:matching` action. Responses
never carry `meta`. The compatibility check treats a unary rpc turning into a
stream, or the reverse, as a breaking change.

## What the client receives

1. The current records: one response per record the read action returns for
   this caller, `removed = false`, `position` the record's index in that list
   (0, 1, 2 ...).
2. One response with `synced = true` and no `result`, right after the last
   current record. It is sent also when there are no records, so a client can
   tell an empty list from one that is still loading.
3. After that, one response for each change, all with `synced = false`:
   * A record that was created or updated, and that the caller can read and the
     action returns, arrives with `removed = false`, its current fields, and `position`: the
       zero-based index it has in the read action's result at that moment, with
       the request's `sort` and `filter` applied.
   * A record that left the caller's view arrives with `removed = true`. It
     left because it was destroyed, because it no longer matches the action's
     filter, or because the caller may no longer read it. `result` then holds
     only the primary key.

A client collects the records until `synced` arrives, shows the whole list at
once, then applies each later response one by one: it removes any copy of the
record's primary key, then inserts the record at `min(position, length)`. A
`removed` response leaves `position` unset. A change that happens while
the snapshot is read arrives after the marker.

`removed` is sent only for a record the stream has sent before. A record the
caller never saw is never announced as removed.

## Who sees what

The notification that wakes a subscription carries no record data, only the
primary key. For every change the subscription runs the read action again,
with the caller as actor, with the request's sort and filter, to find where
the changed record sits in the result. So policies, field policies and
the action's own filter apply to each subscriber on their own, and what one
caller may read never reaches another. Calculations in `fields` are loaded on
every re-read.

## Tenants

The tenant comes from the authenticator, as for any call. On a multitenant
resource a subscription only receives changes written in its own tenant.

## Deadlines and cancellation

A client deadline ends the stream with `DEADLINE_EXCEEDED`. Without one the
stream lasts until the client leaves. When the client cancels or disconnects,
or the deadline passes, the subscription is removed. If a re-read fails, the
stream ends with the matching status (see [Errors](errors.md)) and the cause is
logged once.

## Calling it

With the Elixir stub the reply is a stream of `{:ok, response}` tuples:

```elixir
{:ok, replies} =
  Stub.watch_posts(channel, %V1.WatchPostsRequest{},
    metadata: %{"authorization" => "Bearer token"},
    timeout: 60_000
  )

for {:ok, %V1.WatchPostsResponse{result: post, removed: removed, synced: synced}} <- replies do
  cond do
    synced -> show_collected()
    removed -> forget(post.id)
    true -> remember(post)
  end
end
```

gRPC-Web clients can stream too, so a browser can subscribe.

## Limits

* An endpoint keeps at most `max_subscriptions` subscription streams open at
  once on its node (default `1000`, set on `use AshGrpc.Endpoint`). The next
  one is answered `RESOURCE_EXHAUSTED` and nothing is read for it. A stream
  that ends, for any reason, frees its place. The count is per endpoint, not
  per client: put a limit per client in your interceptors if you need one.
* No backpressure and no coalescing. Every change causes one full read of the
  list (to find the record's position), not a read of one key, so a long list
  makes every change cost more. Every change causes one re-read, and a
  client that reads slowly makes its mailbox grow without bound. Keep
  subscriptions to resources and rates your clients can keep up with.
* No resume cursor. A client that reconnects gets a fresh snapshot, not the
  changes it missed. Treat the snapshot as the truth.
* The login is checked once, when the call starts. Later re-reads use that
  same actor, so a revoked token does not end a running stream. Policies are
  still evaluated on every re-read.
* On several nodes, changes written on another node reach a subscription only
  if the Erlang nodes are connected: the notifier uses `:pg`.
* A subscriber with no tenant, on a multitenant resource, gets no changes
  that were written with a tenant.
* A write that never goes through an Ash action cannot be seen at all, and
  neither can a bulk action of your own that does not run with `notify?: true`
  (see `Ash.bulk_create/4` and its siblings). The library's bulk rpcs do notify.

See [Testing](testing.md) for how to run a stream in a test.

For the client sending many messages on one call, see [Streaming calls](streaming-calls.md).
