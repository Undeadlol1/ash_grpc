defmodule AshGrpc.Domain.Dsl do
  @moduledoc false

  alias AshGrpc.Domain.Rpc
  alias Spark.Dsl.Entity

  @rpc %Entity{
    name: :rpc,
    describe: "One callable action. The proto rpc is the camelized name.",
    target: Rpc,
    args: [:resource, :name, {:optional, :action}],
    transform: {Rpc, :default_action, []},
    schema: [
      name: [type: :atom, required: true, doc: "The rpc name, e.g. `:list_posts`."],
      resource: [
        type: :atom,
        required: true,
        doc:
          "The resource the action belongs to. It must use `AshGrpc.Resource` and have a `grpc` block."
      ],
      action: [
        type: :atom,
        doc:
          "The action to run: a read, create, update, destroy, or a generic action returning the resource, any type with a protobuf mapping, or nothing. Defaults to the action named like the rpc; write it only when they differ."
      ],
      read_action: [
        type: :atom,
        doc:
          "For an update or destroy: the read action that finds the record, run as the caller. Defaults to the resource's primary read action."
      ],
      args: [
        type: {:list, {:or, [:atom, {:tuple, [:atom, :pos_integer]}]}},
        doc:
          "The request fields. Omitted, they come from the action: for an update or destroy the primary key, then for a create, update or destroy the attributes it accepts, then its public arguments. Given, it is exactly these: names (`[:id, :title]`, numbered automatically and kept in the committed `.proto`), or `name: number` pairs (`[id: 1, title: 2]`), or both. `[]` is a request without fields. A name is an action argument, an attribute the action accepts (create, update), or a primary key attribute (update, destroy: it looks the record up). Every request scalar is `optional` on the wire."
      ],
      reserved: [
        type: {:list, :pos_integer},
        default: [],
        doc:
          "Numbers of request fields that were removed. Rendered as `reserved` in the request message, together with the numbers of automatically numbered inputs removed since the committed file."
      ],
      clear_fields: [
        type: {:or, [:boolean, :pos_integer]},
        doc:
          "`repeated string clear_fields` in the request: each name the client lists there is passed to the action as `nil`; see the [Actions](actions.md) guide. On by default for an rpc on an update action; `false` leaves it out, `true` adds it to any other rpc, a number pins its field number."
      ],
      deprecated: [
        type: :boolean,
        default: false,
        doc: "Renders `option deprecated = true;` on the rpc. The rpc still works."
      ],
      bulk?: [
        type: :boolean,
        default: false,
        doc:
          "For a create, update or destroy: one call for many records, all or nothing, through `Ash.bulk_create/4`, `Ash.bulk_update/4` or `Ash.bulk_destroy/4`. See the [Bulk calls](bulk-calls.md) guide."
      ],
      max_bulk_size: [
        type: :pos_integer,
        doc:
          "With `bulk?: true`: the most items one call may carry. More is `INVALID_ARGUMENT` before anything runs. Defaults to 100."
      ],
      streaming: [
        type: {:one_of, [:client, :bidirectional]},
        doc:
          "Makes the request a stream of the rpc's ordinary request message, each run as its own call of the action. `:bidirectional` answers every message at once with a reply holding the result or the error; `:client` answers one summary of the failures when the client is done. Not for `bulk?` or a subscription; `:client` is not for read actions. See the [Streaming calls](streaming-calls.md) guide."
      ],
      max_stream_failures: [
        type: :pos_integer,
        doc:
          "With `streaming: :client`: the most failed messages one call may report. One more ends the call with `RESOURCE_EXHAUSTED`; messages already saved stay saved. Defaults to 100."
      ],
      page: [
        type: {:or, [:boolean, {:list, {:or, [:atom, {:tuple, [:atom, :pos_integer]}]}}]},
        doc:
          "Paging a read that returns many. On by default when the read action has `pagination`: the request gets exactly the fields the action allows (`optional int64 limit`; `offset` with `offset?: true`; `optional string after` and `before` with `keyset?: true`; `optional bool count` with `countable`), and the response gains `bool has_more = 3`, with `count` also `optional int64 count = 4`, with `after` or `before` also `optional string first_keyset = 5` and `optional string last_keyset = 6`. `false` turns it off. `true` is the default stated. `[:limit, :offset]` chooses the fields (`:limit` is required) and `[limit: 1, offset: 2]` pins their numbers. See the [Paging, sorting and filtering](pagination-sort-filter.md) guide."
      ],
      load: [
        type: {:or, [:atom, {:list, :any}]},
        default: [],
        doc:
          "Relationship fields to load and send, as `Ash.Query.load/2` takes them: `load: [:author, comments: [:author]]`. Each must be a relationship that is also a field of the message at that depth. They are loaded as the caller, so the related resource's read policies apply; see the [Actions](actions.md) guide."
      ],
      sort: [
        type: {:or, [:boolean, :pos_integer]},
        doc:
          "`optional string sort` in the request, a read's sort in `Ash.Query.sort_input/2` syntax (`\"-inserted_at,title\"`), public fields only. On by default for a read that returns many; `false` turns it off, a number pins its field number."
      ],
      filter: [
        type: {:or, [:boolean, :pos_integer]},
        doc:
          "`google.protobuf.Struct filter` in the request, a read's filter applied with `Ash.Query.filter_input/2`, public fields only. On by default for a read that returns many; `false` turns it off, a number pins its field number."
      ]
    ]
  }
  @subscription %Entity{
    name: :subscription,
    describe:
      "A server-streaming rpc over a read action: the current records, then each change. See the [Subscriptions](subscriptions.md) guide.",
    target: Rpc,
    auto_set_fields: [stream?: true],
    args: [:resource, :name, {:optional, :action}],
    transform: {Rpc, :default_action, []},
    schema: [
      name: [
        type: :atom,
        required: true,
        doc: "The subscription name, e.g. `:watch_posts`."
      ],
      resource: [
        type: :atom,
        required: true,
        doc:
          "The resource to watch. It must use `AshGrpc.Resource`, and have its primary key on the wire."
      ],
      action: [
        type: :atom,
        doc:
          "The read action (not requiring or defaulting to pagination) that decides which records the caller sees. Defaults to the read action named like the subscription; write it only when they differ."
      ],
      args: [
        type: {:list, {:or, [:atom, {:tuple, [:atom, :pos_integer]}]}},
        doc:
          "The request fields. Omitted, they are the public arguments of the read action. Given, it is exactly these, each an argument of the read action: names (numbered automatically) or `name: number` pairs. `[]` is a request without fields."
      ],
      reserved: [
        type: {:list, :pos_integer},
        default: [],
        doc:
          "Numbers of request fields that were removed. Rendered as `reserved` in the request message."
      ],
      deprecated: [
        type: :boolean,
        default: false,
        doc: "Renders `option deprecated = true;` on the rpc. It still works."
      ],
      load: [
        type: {:or, [:atom, {:list, :any}]},
        default: [],
        doc:
          "Relationship fields to load and send with every record, snapshot and change, as `Ash.Query.load/2` takes them: `load: [:author]`. See the [Actions](actions.md) guide."
      ],
      sort: [
        type: {:or, [:boolean, :pos_integer]},
        doc:
          "`optional string sort` in the request; applied to the snapshot and every re-read. On by default; `false` turns it off, a number pins its field number."
      ],
      filter: [
        type: {:or, [:boolean, :pos_integer]},
        doc:
          "`google.protobuf.Struct filter` in the request; applied to the snapshot and every re-read, so a record that stops matching is sent as removed. On by default; `false` turns it off, a number pins its field number."
      ]
    ]
  }
  @grouped_rpc %{
    @rpc
    | args: [:name, {:optional, :action}],
      transform: {Rpc, :reject_resource, []},
      schema: Keyword.delete(@rpc.schema, :resource)
  }
  @grouped_subscription %{
    @subscription
    | args: [:name, {:optional, :action}],
      transform: {Rpc, :reject_resource, []},
      schema: Keyword.delete(@subscription.schema, :resource)
  }
  @resource_group %Entity{
    name: :resource,
    describe:
      "The calls of one resource: `rpc` and `subscription` inside take no resource. Same as writing the resource on each one-line `rpc` and `subscription`.",
    target: AshGrpc.Domain.ResourceGroup,
    args: [:resource],
    entities: [rpcs: [@grouped_rpc], subscriptions: [@grouped_subscription]],
    schema: [
      resource: [
        type: :atom,
        required: true,
        doc:
          "The resource the calls inside belong to. It must use `AshGrpc.Resource` and have a `grpc` block."
      ]
    ]
  }
  @service %Entity{
    name: :service,
    describe: "A gRPC service: a named group of rpcs and subscriptions.",
    target: AshGrpc.Domain.Service,
    args: [:name],
    entities: [
      rpcs: [@rpc, @resource_group],
      subscriptions: [@subscription]
    ],
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "The service name, e.g. `\"Posts\"`. Unique in the domain."
      ]
    ]
  }
  @grpc %Spark.Dsl.Section{
    name: :grpc,
    describe: "The protobuf package and services of this domain.",
    entities: [@service],
    schema: [
      package: [
        type: :string,
        required: true,
        doc:
          "The protobuf package, e.g. `\"blog.v1\"`. The `.proto` file is written to the path it implies (`blog/v1.proto`)."
      ]
    ]
  }

  def sections, do: [@grpc]
end
