# Evolving your schema

Clients are built from your `.proto` and keep working long after you change
the server. protobuf identifies a field by its number, never by its name. So
the rules are about numbers.

## Where the numbers come from

A resource lists its fields without numbers:

```elixir
grpc do
  fields [:id, :title, :inserted_at]
end
```

The numbers are chosen when the endpoint compiles, from the committed
`.proto` file of the package (`<proto_output>/blog/v1.proto`):

- No file yet, or the file has no message for this resource: 1, 2, 3... in
  list order.
- A field the file already has (same message, same name) keeps its number,
  wherever it now sits in the list.
- A new field gets the next number above the highest one the message ever
  used (fields, `reserved` numbers and numbers you wrote). 19000 to 19999
  belong to protobuf and are skipped.
- A field that is gone has its number added to `reserved`, and the file keeps
  it reserved from then on. A field added back later under the same name gets
  a new number.

So the file is the memory, and three things follow:

- Set `config :ash_grpc, proto_output: "priv/protos"`. Without it an
  un-numbered field stops the build, because nothing would keep its number
  the same between builds.
- Commit the generated files.
- They must be present when the app is compiled, also for a release: in a
  Docker build, copy `priv/protos` into the image before `mix compile`.
  Otherwise the build numbers from 1 again and serves different numbers.

You can write a number yourself: `fields [:id, :body, title: 7]`. A written
number is used as is, and the automatic ones go around it. Pinning is also
how to rename a field and keep its number: `fields [:id, headline: 2]` where
the file had `title = 2`. (The generator reports the rename as breaking,
since generated client code changes names; pass `--allow-breaking`.)

Written numbers that clash stop the build with the message and field named:
a number the file gives to another field that is still listed without a
number, or a number the file reserves. So does a file the library cannot
read, or one that gives one number to two fields.

A resource whose fields all have written numbers (`fields id: 1, title: 2`)
does not use the file at all and works as before: nothing is reserved for
you.

## The rules

- A number never changes meaning. To change a field's type, give the new field
  a new number.
- A number you stop using is retired with `reserved`, so nobody reuses it.
  With un-numbered fields this happens by itself.
- A field clients should stop using is marked `deprecated`. It is still served.
- Append new enum values at the end of `values/0` (or `one_of`). The proto
  numbers follow that order, so reordering or removing a value renumbers the
  ones after it and is reported as breaking.

## Retire a field

With un-numbered fields, remove it from `fields`. The next
`mix ash_grpc.gen.protos` reserves its number and prints a line such as
`Retired Post.body (field 3); its number is now reserved.`

With written numbers, remove it from `fields` and list its number in
`reserved`:

```elixir
grpc do
  fields id: 1, title: 2
  reserved [3]
end
```

A request message follows the same rules. Inputs that come from the action, or
are listed without numbers, keep their number in the committed `<Rpc>Request`
message, a new input (an attribute added to `accept`, a new argument) gets the
next number, and a removed one is reserved and never reused. With written
numbers, `reserved:` goes on the `rpc`:

```elixir
rpc MyApp.Blog.Post, :get_post, :by_id, args: [id: 1], reserved: [2]
```

The `.proto` gets `reserved 3;` in the message. A field using a reserved
number, or a number listed twice in `reserved`, stops the build.

## Deprecate

```elixir
grpc do
  fields id: 1, title: 2
  deprecated [:title]
end

rpc MyApp.Blog.Post, :nap, :nap, deprecated: true
```

`deprecated [:title]` keeps the field served and renders
`... title = 2 [deprecated = true];`. `deprecated: true` on an rpc renders
`option deprecated = true;` in the rpc. A name in `deprecated` that is not in
`fields` stops the build.

## The committed `.proto` is the history

Generate the files and commit them:

```sh
mix ash_grpc.gen.protos --endpoint MyAppWeb.GrpcEndpoint --output priv/protos
```

There is one file per package (`blog/v1.proto`). A file whose text did not
change is not written again. The next time the task runs,
it compares the file on disk with the new text before writing. If clients
built from the old file would break, it writes nothing and fails, listing each
change and how to fix it.

### What counts as breaking

- a number that now has a different name, type, or `optional` / `repeated`
  label (this includes a field that starts or stops allowing nil);
- a field that is gone while its number is not in `reserved`;
- a `reserved` number that is free again, or used by a field;
- a message, enum, service or rpc that is gone;
- an enum value that is gone or now has another number (adding a value is fine);
- a `.proto` file the endpoint no longer renders (it is deleted only with
  `--allow-breaking`);
- an rpc whose request or response type changed.

Adding messages, fields, rpcs and services, marking things deprecated and
retiring a field by reserving its number never fail. Turning on
`response_meta: true` is one of those: it adds `optional string meta = 2;`.

A failure looks like this:

```text
Nothing written: these changes would break clients built from the committed files.
  - priv/protos/blog/v1.proto: message Post: field 3 (`optional string body`) was removed but its number is not reserved. Add `reserved 3` to Post.
```

If you mean the break, pass `--allow-breaking`:

```sh
mix ash_grpc.gen.protos --endpoint MyAppWeb.GrpcEndpoint --output priv/protos --allow-breaking
```

The comparison reads only text this library renders. A committed file it
cannot read fails with `is not a file this task wrote`, and
`--allow-breaking` overwrites it.

Use the comparison from code with
`AshGrpc.Proto.Compatibility.check(old_text, new_text)`: it returns `:ok` or a
list of sentences.

## Check for drift in CI

`--check` writes nothing and fails when a file on disk differs from what the
endpoint would generate, does not exist, or is a `.proto` under the output
directory that the endpoint no longer renders:

```sh
mix ash_grpc.gen.protos --endpoint MyAppWeb.GrpcEndpoint --output priv/protos --check
```

Run it in CI. A change to a resource or domain then cannot merge without the
regenerated `.proto` in the same commit, and the regeneration has already
passed the compatibility comparison.

## Descriptions

The `description` of a resource, attribute, calculation, action argument and
action is written into the `.proto` as `//` comment lines above its message,
field or rpc (one line per line of the description). The compatibility check
skips comment lines, so changing a description is never a breaking change.
