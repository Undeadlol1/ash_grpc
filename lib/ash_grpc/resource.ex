defmodule AshGrpc.Resource do
  @moduledoc """
  Puts a resource on the wire as a protobuf message.

      use Ash.Resource, domain: MyApp.Blog, extensions: [AshGrpc.Resource]

  That is enough: like `ash_json_api` and `ash_graphql`, every public
  attribute, calculation, aggregate and relationship is sent, in that order.
  Marking a field `public?: true` therefore puts it on the wire for every rpc
  of the resource; field policies still apply. Left out without an error:
  sensitive fields, calculations with a required argument, fields whose type
  has no protobuf mapping, and relationships to a resource without this
  extension. Private fields are never sent.

      grpc do
        hide_fields [:internal_note]
      end

  `hide_fields` removes public fields from that set. `fields` is the
  opposite, an allowlist; with it only the listed fields are sent and a
  listed field that cannot be sent stops the build.

      grpc do
        fields [:id, :title, :inserted_at]
        deprecated [:inserted_at]
      end

  The message is named after the resource module (`MyApp.Blog.Post` is
  `Post`); set `proto_message "Article"` to name it yourself.

  Each field is an attribute, calculation, aggregate or relationship. protobuf
  knows a field by its number, and a number must never change once a client
  uses it, so AshGrpc numbers them for you and keeps the numbers in the
  committed `.proto` file under `config :ash_grpc, proto_output: "priv/protos"`:
  1, 2, 3... in list order the first time, then a field in the file keeps its
  number, a new field gets the next number above the highest ever used, and a
  removed field's number is reserved. Commit the generated file and keep it in
  every build (in a Docker image, copy it in before `mix compile`).

  `name: number` pins a number (`fields [:id, :body, title: 2]`), which is how
  a field is renamed without retiring its number. With every number written
  (`fields id: 1, title: 2`) the file is not used: retire a number yourself
  with `reserved [3]`. A field clients should stop using goes in `deprecated`.

  A resource is only reachable once a domain names it in an `rpc`. The block
  is checked at compile time: a repeated name or number, a number that is not
  positive, a reserved number in use, an unknown field and a type with no
  protobuf mapping all stop the build. A pinned number that the committed file
  gives to another listed field also stops the endpoint's build.

  Read the block back with `AshGrpc.Resource.Info`. For the options see the
  [DSL reference](dsls/DSL-AshGrpc.Resource.md); for the rules around numbers
  see the [Evolving your schema](evolving-your-schema.md) guide.
  """

  @grpc %Spark.Dsl.Section{
    name: :grpc,
    describe: "The protobuf message this resource becomes on the wire.",
    schema: [
      proto_message: [
        type: :string,
        doc:
          ~s{The protobuf message name, e.g. `"Post"`. Defaults to the last segment of the resource module (`MyApp.Blog.Post` is `"Post"`). It must be unique in the package, and not clash with an rpc's `<Rpc>Request` or `<Rpc>Response` message.}
      ],
      fields: [
        type: {:list, {:or, [:atom, {:tuple, [:atom, :any]}]}},
        doc:
          "Without it every public attribute, calculation, aggregate and relationship is on the wire (see `hide_fields`). Given, it is the allowlist: attributes, calculations, aggregates and public relationships on the wire, in order: `[:id, :title]`. AshGrpc gives each name a protobuf field number and keeps it in the committed `.proto` file (see `proto_output`), so a number never changes. Pin a number with `name: number` (`[:id, :body, title: 2]`, or `id: 1, title: 2` for every field); a pinned number is positive and unique in the message. A field is `optional` on the wire when the attribute, calculation or aggregate allows nil. A relationship is a message of its destination resource (which needs its own `grpc` block), `repeated` when to-many; the rpc's `load` says which are sent. An embedded resource with this block can be the type of another resource's field; it then becomes a nested message, and may not list calculations."
      ],
      hide_fields: [
        type: {:list, :atom},
        default: [],
        doc:
          "Public fields to leave off the wire when `fields` is not given: `[:internal_note]`. A name that is not a public field of the resource stops the build, and so does using it together with `fields`."
      ],
      reserved: [
        type: {:list, :pos_integer},
        default: [],
        doc:
          "Numbers of fields that were removed from `fields`. Rendered as `reserved` in the `.proto`, together with the numbers the committed file reserves and, when a field has no written number, the numbers of fields removed since. No field may use them."
      ],
      deprecated: [
        type: {:list, :atom},
        default: [],
        doc: "Names from `fields` that are still served but rendered with `[deprecated = true]`."
      ]
    ]
  }
  use Spark.Dsl.Extension,
    sections: [@grpc],
    transformers: [
      AshGrpc.Resource.Transformers.AddNotifier,
      AshGrpc.Resource.Transformers.ValidateFields
    ]
end
