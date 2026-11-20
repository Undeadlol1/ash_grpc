# Types

Fields of a resource, and request fields of an rpc, must have an Ash type
with a protobuf mapping:

| Ash type | protobuf |
|---|---|
| `:string`, `:ci_string`, `:uuid`, `:uuid_v7` | `string` |
| `:atom` | `string` (the name) |
| any `Ash.Type.Enum`, `:atom` with `one_of` | an `enum` |
| `:map` | `google.protobuf.Struct` |
| `:integer` | `int64` |
| `:float` | `double` |
| `:boolean` | `bool` |
| `:utc_datetime`, `:utc_datetime_usec`, `:datetime` | `google.protobuf.Timestamp` |
| `:date`, `:time`, `:time_usec`, `:naive_datetime`, `:duration` | `string` (ISO 8601) |
| `:decimal` | `string` |
| `:binary` | `bytes` |
| `:url_encoded_binary` | `string` (unpadded URL-safe base64) |
| `{:array, T}` of any type above | `repeated` of T's mapping |
| an embedded resource, a `:struct` with `instance_of:` one | its own message |
| a typed struct, a `:map`, `:keyword`, `:struct` or `:tuple` with `fields` | a nested message |
| `{:array, {:array, T}}`, at any depth | `repeated` of a wrapper message holding `repeated T values = 1` |

An atom is sent as its name. A `NewType` is mapped as the type it is a subtype of.

## Enums

An `Ash.Type.Enum` (or a `NewType` over one) is a protobuf `enum` named after
the module's last part: `MyApp.Blog.PostStatus` is `PostStatus`. An `:atom`
with `constraints: [one_of: [...]]` is an enum named `<Parent><FieldName>`, by
the same rule as an unnamed nested message (`PostStatus` for the `status`
field of `Post`), or after its `NewType`.

```proto
enum PostStatus {
  POST_STATUS_UNSPECIFIED = 0;
  POST_STATUS_DRAFT = 1;
  POST_STATUS_LIVE = 2;
}
```

Every enum has `<PREFIX>_UNSPECIFIED = 0`, then one value per Ash value in
the order of `values/0` (or `one_of`), numbered from 1 and named
`<PREFIX>_<VALUE>`; the prefix is the enum name in `SCREAMING_SNAKE_CASE`.
Value descriptions (`use Ash.Type.Enum, values: [draft: "Not public"]`)
become `//` comments. A value that is not letters, digits and underscores
starting with a letter, or two values with one protobuf name, stops the build,
as does one enum name with different values in a package, an enum and a
message with one name, or one value name in two enums.

`UNSPECIFIED`, or an unset field, is "not sent": it reaches the action as no
value, like any absent field. A number the enum does not know is
`INVALID_ARGUMENT` naming the field ("is not a known PostStatus"). A response
sends the value's number; an empty value is sent unset. Filters and `sort`
speak Ash's own strings (`"live"`), not the protobuf names. Client input never
becomes an atom any other way.

A map is a `google.protobuf.Struct`, which is JSON: atoms, decimals and dates
are sent as the strings Jason renders, and every number is a `double`, so an
integer above 2^53 loses precision. A request Struct reaches Ash as a map with
string keys, whole numbers as integers, then Ash casts it (`fields`
constraints included). A `.proto` that uses one imports
`google/protobuf/struct.proto`. A Struct has presence of its own and is never
written `optional`. Changing a field between `string` and Struct is a breaking
change, like any other change of type.

A decimal is sent as text, so no precision is
lost. A timestamp is seconds and nanoseconds since the Unix epoch; a
`.proto` that uses one imports `google/protobuf/timestamp.proto`. A
`:datetime` in another zone is sent as the same instant and comes back in UTC.

A time (`08:30:00.123456`), a naive datetime (`2026-11-12T08:30:00`) and a
duration (`P1MT2H`) are ISO 8601 text. A naive datetime has no zone, so it is
not a Timestamp. A duration is not a `google.protobuf.Duration` either: Ash
durations keep months and days, which have no fixed number of seconds. A
request string goes to Ash's casting, so a malformed one is
`INVALID_ARGUMENT`.

A `:url_encoded_binary` is the base64 text Ash casts it from, since Ash would
also try to base64-decode raw bytes.

## Arrays

`{:array, T}` is `repeated`, in resource messages and requests, and is never
written `optional`. Protobuf cannot tell an empty list from an absent one, so:

- a nil array is sent as an empty list;
- in a request, an empty list is "not sent", like any other omitted field: the
  action does not see it, and an update keeps the stored value. To set an
  array to nil, list its name in `clear_fields`; to empty it, use an action
  argument the action turns into `[]`.

One with `nil_items?: true` is rejected: protobuf has no way to say it. Each item is decoded and cast like a single value,
so one bad item is `INVALID_ARGUMENT` naming the field.

An array of arrays has no "repeated repeated" in protobuf, so each inner list is a wrapper message with one field, `repeated T values = 1`, and the outer field is `repeated` of the wrapper. The wrapper is named `<Parent><FieldName>Item`; a third level repeats the rule (`ParcelCubeItemValuesItem`). T is anything an array may hold.

    repeated ParcelGridItem grid = 4;

    message ParcelGridItem {
      repeated int64 values = 1;
    }

An empty inner list is kept; an empty outer list is "not sent", as above.

## Nested messages

An embedded resource is a message from its own `grpc` block, like any
resource: `proto_message`, field numbers, `reserved` and `deprecated` work the
same. Without `fields` it sends its public attributes; it may not list
calculations, which are not loaded inside another record. One without
`AshGrpc.Resource` is rejected.

A map, keyword or struct with `fields` constraints is a message whose field
numbers follow the order of `fields`: 1, 2, 3. Reordering, inserting or
removing a field renumbers the ones after it, which is a breaking change and
`mix ash_grpc.gen.protos` refuses it; add new fields at the end. A field is
`optional` unless it has `allow_nil?: false`.

A tuple (`:tuple` with `fields`) is the same kind of message, with the fields
in the order of `fields`; it reaches Ash as an Elixir tuple in that order.

    message ParcelPoint {
      int64 x = 1;
      optional int64 y = 2;
    }

A typed struct (`Ash.TypedStruct`) or another `NewType` is named after the last
part of its module: `MyApp.Dimensions` is `Dimensions`. Any other nested
message is named `<Parent><FieldName>`: `weight` on `Parcel` is `ParcelWeight`.
In a request, an accepted attribute keeps its resource's name (`ParcelWeight`),
and an argument takes the request's (`PackParcelRequestBox`).

Messages with the same name in a package must be identical, and are rendered
once. Two different ones, or one named like an rpc's `<Rpc>Request` or
`<Rpc>Response`, stop the endpoint from compiling.

A nested request message reaches Ash as a map with the fields that were set;
Ash casts it. Updating an embedded resource is Ash's update of it, so fields
the request leaves unset keep their stored value. A field violation inside a
nested value names its path, e.g. `labels[1].text`.

## Unions

An `Ash.Type.Union` (inline, or a `NewType` of one) is a message with one
`oneof value`, holding a member per union type. The member is named after the
union type and numbered in the order of `constraints[:types]`, from 1; as with
`fields` constraints, add new types at the end. A member is mapped like any
other type: a scalar, an embedded resource, a typed struct, a map with `fields`.

    message ParcelShape {
      oneof value {
        Circle circle = 1;
        Square square = 2;
      }
    }

The message is named like other nested messages (`<Parent><FieldName>`, or the
last part of a `NewType`'s module). `{:array, :union}` is `repeated` of it.

- In a response, `%Ash.Union{type: :circle, value: v}` sets the member
  `circle`. A nil union, or one whose value is nil, is sent unset.
- In a request, the member that is set becomes `%Ash.Union{type: :circle,
  value: v}` and Ash casts it, tagged unions included. A union message with no
  member set is "not sent", like any other omitted field.
- A union member that is an array is rejected, because a `oneof` cannot hold
  `repeated`: wrap it in a typed struct or a map with `fields`.
- A violation inside a member names the union field (`shape`), not the member.
- Removing, renumbering or retyping a member is a breaking change, like for
  any field; adding one is not.

## Optional

In a resource message, a field is `optional` when its attribute or
calculation allows nil. A timestamp has presence of its own and is never
written `optional`.

A field that a field policy can hide (`:*` covers every non-key field) is
always `optional`, even if its attribute is `allow_nil? false`. When the caller
may not see it, it is sent unset and the rest of the record is still sent. A
hidden array is sent empty. Resources without field policies are unchanged.

Every scalar in a request message is `optional`. See [Actions](actions.md).

## What is rejected

Any other type stops the build, with an error naming the field, its type and
the reason: `:term`, `:function`, `:module`, `:vector` (use
`{:array, :float}`), `:file`, `:range`, a union with an array member or an unmappable one, a `:struct` or
`:keyword` without `fields` constraints, arrays with
`nil_items?: true`, and embedded resources without a `grpc` block.

For a resource field the build stops when the resource compiles. For an rpc
argument it stops when the endpoint compiles. `AshGrpc.Types.kind/1` tells
whether a type is mapped.
