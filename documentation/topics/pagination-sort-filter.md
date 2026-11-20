# Paging, sorting and filtering

An `rpc` on a read that returns many lets the client page, sort and filter the
result. All three are on by default; you write nothing.

```elixir
rpc MyApp.Blog.Post, :list_posts, :read
```

- `sort` and `filter` are request fields on every such rpc.
- Paging is there when the Ash read action has `pagination` (Ash's default
  `:read` does). The request gets exactly the keys the action allows.
- Field numbers are chosen for you and kept in the committed `.proto`.

For a default `:read` the request is `limit`, `offset`, `after`, `before`,
`count`, `sort` and `filter`, and the response gains `has_more` and the
paging fields below.

A default field with the same name as one of the rpc's inputs (an argument
called `sort`, say) stops the build and names the opt-out.

## Turning one off

```elixir
rpc MyApp.Blog.Post, :list_posts, :read, sort: false, filter: false, page: false
```

Each can be turned off alone. A number that was already in the committed
`.proto` is reserved, so old clients keep working. `sort: false`,
`filter: false` and `page: false` are also accepted on an rpc that is not a
read returning many. A read that requires pagination, or has
`paginate_by_default?: true`, needs paging: with `page: false` the build
stops.

## Choosing the page keys

`page: [:limit, :offset]` sends only those keys. `limit` is required, and
every key must be allowed by the action, or the build stops:

| key      | request field           | needs                |
| -------- | ----------------------- | -------------------- |
| `limit`  | `optional int64 limit`  |                      |
| `offset` | `optional int64 offset` | `offset?: true`      |
| `after`  | `optional string after` | `keyset?: true`      |
| `before` | `optional string before`| `keyset?: true`      |
| `count`  | `optional bool count`   | `countable` not false |

Without `page`, the keys are all the ones the action allows, for example
these for an action with `offset?`, `keyset?` and `countable`:

```elixir
read :list do
  pagination offset?: true, keyset?: true, countable: true,
             required?: false, default_limit: 20, max_page_size: 100
end
```

## Explicit numbers

You can still write the field numbers, and they are kept as written:

```elixir
rpc MyApp.Blog.Post, :list_posts, :list,
  args: [author_id: 1],
  page: [limit: 2, offset: 3, after: 4, before: 5, count: 6],
  sort: 7,
  filter: 8
```

Names and numbers mix (`page: [:limit, offset: 9]`). Automatic numbers go
around the ones you wrote. A number or name used twice in one request, or a
number in the rpc's `reserved`, stops the build. `page`, `sort` and `filter`
written as a value (not `false`) on an action that is not a read returning
many (a create, or a read with `get? true`) stop the build too.

## Paging

Paging needs a read action with `pagination`. A read without it gets no
paging fields.

The response keeps `result = 1` and, with `response_meta: true`, `meta = 2`.
It gains fields with fixed numbers, so they never collide and never move:

```proto
message ListPostsResponse {
  repeated Post result = 1;
  bool has_more = 3;
  optional int64 count = 4;
  optional string first_keyset = 5;
  optional string last_keyset = 6;
}
```

`has_more` is always there. `count` is there when the request has `count`, and is
set when the client sent `count: true`. `first_keyset` and `last_keyset` are
there when the request has `after` or `before`.

- Offset paging: send `limit` and `offset`. Fetch the next page with
  `offset + limit` while `has_more` is true.
- Keyset paging: send `limit`, then `after: last_keyset` for the next page or
  `before: first_keyset` for the previous one. With `before`, `has_more` says
  whether there are more records before. Keep the same `sort` and `filter`
  between pages. A malformed keyset is `INVALID_ARGUMENT`.

Ash applies the action's settings: a request without `limit` uses
`default_limit`, a `limit` over `max_page_size` is cut to it, and a read with
`required?: true` and no `default_limit` answers a request without `limit`
with `INVALID_ARGUMENT`. With no limit at all on an optional read, every record
is sent and `has_more` is false.

## Sorting

`optional string sort` is in the request (`sort: <number>` pins its number). It takes the
string syntax of `Ash.Query.sort_input/2` (the one AshJsonApi uses): field
names separated by commas, `-` for descending.

```elixir
%V1.ListPostsRequest{sort: "-inserted_at,title"}
```

Only public attributes, calculations and aggregates can be sorted on. An
unknown or private field is `INVALID_ARGUMENT` with a field violation on
`sort`. The sort is added after the action's own.

## Filtering

`google.protobuf.Struct filter` is in the request (`filter: <number>` pins its
number). It
takes the map syntax of `Ash.Query.filter_input/2`:

```elixir
filter =
  AshGrpc.Types.encode(:struct, %{
    "or" => [
      %{"title" => %{"contains" => "grpc"}},
      %{"views" => %{"greater_than" => 100}}
    ]
  })

%V1.ListPostsRequest{filter: filter}
```

A plain value means equality: `%{"title" => "Hello"}`. Only public fields can
be filtered on. An unknown or private field, or an unknown operator, is
`INVALID_ARGUMENT` with a field violation on `filter`.

The filter narrows the action's result; it never widens it. Policies, the
action's own filter and the tenant still apply, so a client cannot filter its
way to records it may not read.

## Subscriptions

A `subscription` takes `sort` and `filter` the same way, on by default. They apply to the
snapshot and to every re-read, so a record that stops matching the filter is
sent as removed. `page` is not an option of a subscription; a subscription
sends every record, so its read cannot require or default to pagination.

```elixir
subscription MyApp.Blog.Post, :watch_posts, :read, sort: false
```

## Evolving

The new fields are ordinary fields to the [breaking-change check](evolving-your-schema.md):
adding paging, sorting or filtering, or a key of `page`, is fine. Turning
off `sort`, `filter` or a key of `page` removes a request field; its number
is reserved for you from the committed `.proto`. Turning off `page`, or its `count`, `after` or `before`
key, also removes response fields, which is a breaking change.
