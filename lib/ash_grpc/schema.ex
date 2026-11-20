defmodule AshGrpc.Schema do
  @moduledoc """
  The protobuf model derived from domains: one package per domain, with its
  resource messages, nested messages, request and response messages, and
  services.

  An embedded resource becomes a message from its own `grpc` block. A map,
  keyword or struct with `fields` constraints becomes a message numbered in
  declaration order, named after its `NewType` (a typed struct) or else
  `<Parent><FieldName>`, where the parent of an accepted attribute in a request
  is the resource message. Messages with one name must be identical.

  `AshGrpc.Endpoint` compiles modules from it and `AshGrpc.Proto` renders it
  as `.proto` text, so the two cannot disagree.
  """

  alias Ash.Resource.Info
  alias AshGrpc.Domain.Info, as: DomainInfo
  alias AshGrpc.Resource.Info, as: ResourceInfo
  alias Spark.Error.DslError

  @type field :: %{
          required(:name) => atom(),
          required(:number) => pos_integer(),
          required(:kind) => AshGrpc.Types.kind() | {:message, String.t()},
          required(:optional?) => boolean(),
          required(:repeated?) => boolean(),
          optional(:deprecated?) => boolean(),
          optional(:description) => String.t() | nil,
          optional(:source) =>
            :argument | :attribute | :primary_key | :clear_fields | :page | :sort | :filter,
          optional(:type) => term(),
          optional(:constraints) => keyword(),
          optional(:argument?) => boolean(),
          optional(:load?) => boolean(),
          optional(:relationship?) => boolean()
        }

  @doc """
  The packages of the given domains. With `response_meta: true` every unary
  response message also has `optional string meta = 2;`. A subscription's
  response has `bool removed = 2;`, `bool synced = 3;` and `optional uint32 position = 4;` instead. An rpc with
  `page` has `bool has_more = 3;`, and as its `page` allows
  `optional int64 count = 4;`, `optional string first_keyset = 5;` and
  `optional string last_keyset = 6;`.

  `previous: %{relative_path => text}` holds the committed `.proto` files
  (`AshGrpc.Endpoint` reads them from `proto_output`); fields listed without a
  number are numbered from them. Without it such fields stop the build.
  """
  @spec build([module()], keyword()) :: [map()]
  def build(domains, opts \\ []) do
    response_meta? = Keyword.get(opts, :response_meta, false)
    previous = Keyword.get(opts, :previous)
    Enum.map(domains, &package(&1, response_meta?, previous))
  end

  @doc false
  def proto_file(package), do: String.replace(package, ".", "/") <> ".proto"

  defp package(domain, response_meta?, previous) do
    with {:error, error} <-
           AshGrpc.Domain.Verifiers.ValidateRpcs.verify(domain.spark_dsl_config()) do
      raise error
    end

    package = DomainInfo.grpc_package!(domain)
    file = proto_file(package)
    committed = if previous, do: {file, previous[file]}, else: :unconfigured
    services = Enum.map(DomainInfo.grpc(domain), &service(&1, response_meta?, committed))
    resources = for s <- services, rpc <- s.rpcs, uniq: true, do: rpc.resource

    nested = %{
      domain: domain,
      committed: committed,
      order: [],
      messages: %{},
      enum_order: [],
      enums: %{}
    }

    nested = Enum.reduce(resources, nested, &add_resource/2)
    {services, nested} = Enum.map_reduce(services, nested, &nest_service/2)
    verify_rpc_names(services, nested)
    verify_enum_value_names(nested)

    %{
      package: package,
      file: file,
      domain: domain,
      messages: nested.order |> Enum.reverse() |> Enum.map(&nested.messages[&1]),
      enums: nested.enum_order |> Enum.reverse() |> Enum.map(&nested.enums[&1]),
      services: services
    }
  end

  defp nest_service(service, nested) do
    {rpcs, nested} =
      Enum.map_reduce(service.rpcs, nested, fn rpc, nested ->
        resource_name = ResourceInfo.grpc_proto_message!(rpc.resource)
        nest_request = &nest_field(&1, request_parent(&1, resource_name, rpc.request.name), &2)

        nested = nest_item(rpc.bulk_item, nest_request, nested)
        {fields, nested} = Enum.map_reduce(rpc.request.fields, nested, nest_request)

        {response_fields, nested} = nest_fields(rpc.response.fields, rpc.proto_name, nested)
        rpc = put_in(rpc.response.fields, response_fields)

        rpc = put_in(rpc.request.fields, fields)
        {Map.put(rpc, :loads, loads(nested.messages, resource_name, rpc)), nested}
      end)

    {%{service | rpcs: rpcs}, nested}
  end

  defp request_parent(field, resource_name, request_name),
    do: if(field[:source] == :attribute, do: resource_name, else: request_name)

  defp nest_item(nil, _nest_request, nested), do: nested

  defp nest_item(item, nest_request, nested) do
    {fields, nested} = Enum.map_reduce(item.fields, nested, nest_request)
    put_nested(nested, %{name: item.name, resource: nil, fields: fields, reserved: item.reserved})
  end

  defp add_resource(resource, nested) do
    name = ResourceInfo.grpc_proto_message!(resource)

    case nested.messages do
      %{^name => %{resource: ^resource}} ->
        nested

      %{^name => _other} ->
        clash!(nested, name)

      _ ->
        message = resource_message(resource, nested.committed)
        nested = put_message(nested, message)
        {fields, nested} = nest_fields(message.fields, name, nested)
        put_in(nested.messages[name].fields, fields)
    end
  end

  defp nest_fields(fields, parent, nested),
    do: Enum.map_reduce(fields, nested, &nest_field(&1, parent, &2))

  defp nest_field(%{kind: {:resource, resource}} = field, _parent, nested) do
    nested = add_resource(resource, nested)
    {%{field | kind: {:message, ResourceInfo.grpc_proto_message!(resource)}}, nested}
  end

  defp nest_field(%{kind: {:fields, name, fields}} = field, parent, nested) do
    name = name || parent <> Macro.camelize(Atom.to_string(field.name))
    {fields, nested} = nest_fields(fields, name, nested)
    message = %{name: name, resource: nil, fields: fields, reserved: []}

    {%{field | kind: {:message, name}}, put_nested(nested, message)}
  end

  defp nest_field(%{kind: {:tuple, name, fields}} = field, parent, nested) do
    name = name || parent <> Macro.camelize(Atom.to_string(field.name))
    {fields, nested} = nest_fields(fields, name, nested)
    message = %{name: name, resource: nil, fields: fields, reserved: [], shape: :tuple}

    {%{field | kind: {:message, name}}, put_nested(nested, message)}
  end

  defp nest_field(%{kind: {:wrapper, kind}} = field, parent, nested) do
    name = parent <> Macro.camelize(Atom.to_string(field.name)) <> "Item"
    values = AshGrpc.Types.put_kind(%{name: :values, number: 1, optional?: false}, {:array, kind})
    {values, nested} = nest_field(values, name, nested)
    message = %{name: name, resource: nil, fields: [values], reserved: [], shape: :list}

    {%{field | kind: {:message, name}}, put_nested(nested, message)}
  end

  defp nest_field(%{kind: {:union, name, members}} = field, parent, nested) do
    name = name || parent <> Macro.camelize(Atom.to_string(field.name))
    {members, nested} = nest_fields(members, name, nested)
    message = %{name: name, resource: nil, fields: members, reserved: [], oneof?: true}

    {%{field | kind: {:message, name}}, put_nested(nested, message)}
  end

  defp nest_field(%{kind: {:enum, enum}} = field, parent, nested) do
    name = enum.name || parent <> Macro.camelize(Atom.to_string(field.name))

    enum = %{
      name: name,
      values: AshGrpc.Types.enum_values(name, enum.values),
      source: "#{parent}.#{field.name}"
    }

    {%{field | kind: {:enum_type, name}}, put_enum(nested, enum)}
  end

  defp nest_field(field, _parent, nested), do: {field, nested}

  defp put_enum(nested, %{name: name} = enum) do
    case nested.enums do
      %{^name => %{values: values}} when values == enum.values ->
        nested

      %{^name => other} ->
        clash!(
          nested,
          name,
          ", with different values: #{other.source} and #{enum.source}",
          "Enum"
        )

      _ ->
        %{
          nested
          | enum_order: [name | nested.enum_order],
            enums: Map.put(nested.enums, name, enum)
        }
    end
  end

  defp put_nested(nested, %{name: name} = message) do
    case nested.messages do
      %{^name => ^message} -> nested
      %{^name => _other} -> clash!(nested, name)
      _ -> put_message(nested, message)
    end
  end

  defp put_message(nested, message),
    do: %{
      nested
      | order: [message.name | nested.order],
        messages: Map.put(nested.messages, message.name, message)
    }

  defp verify_rpc_names(services, nested) do
    rpc_owners =
      for s <- services,
          rpc <- s.rpcs,
          m <- rpc_messages(rpc),
          do: {m.name, rpc_label(rpc)}

    message_owners = for name <- nested.order, do: {name, "a message of that name"}

    enum_owners =
      for {name, enum} <- nested.enums, do: {name, "the enum from #{enum.source}"}

    clash =
      (rpc_owners ++ message_owners ++ enum_owners)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.find(fn {_name, owners} -> length(owners) > 1 end)

    with {name, owners} <- clash do
      clash!(nested, name, ": " <> Enum.join(owners, ", "))
    end
  end

  defp verify_enum_value_names(nested) do
    clash =
      nested.enums
      |> Enum.flat_map(fn {name, enum} -> for v <- enum.values, do: {v.name, name} end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.find(fn {_value, enums} -> length(enums) > 1 end)

    with {value, enums} <- clash do
      raise DslError,
        module: nested.domain,
        path: [:grpc],
        message:
          "Enum value name #{inspect(value)} is defined more than once in this package, " <>
            "by the enums #{Enum.join(enums, ", ")}. Give one of the enums another name."
    end
  end

  @doc false
  def rpc_messages(%{streaming: :client} = rpc), do: [rpc.request | rpc.stream_messages]
  def rpc_messages(rpc), do: [rpc.request, rpc.response | rpc.stream_messages]

  defp rpc_label(%{stream?: true, name: name}), do: "subscription #{inspect(name)}"
  defp rpc_label(rpc), do: "rpc #{inspect(rpc.name)}"

  defp clash!(nested, name, detail \\ ", with different fields", noun \\ "Message") do
    raise DslError,
      module: nested.domain,
      path: [:grpc],
      message:
        "#{noun} name #{inspect(name)} is defined more than once in this package#{detail}. " <>
          "Give one of them another name."
  end

  defp service(service, response_meta?, committed) do
    %{
      name: service.name,
      rpcs: Enum.map(service.rpcs ++ service.subscriptions, &rpc(&1, response_meta?, committed))
    }
  end

  defp number_request(rpc, name, fields, committed) do
    entries = Enum.map(fields, &if(&1.number, do: {&1.name, &1.number}, else: &1.name))

    {numbered, reserved} =
      AshGrpc.FieldNumbers.assign(rpc.resource, name, entries, rpc.reserved, committed)

    numbers = Map.new(numbered)
    {Enum.map(fields, &%{&1 | number: numbers[&1.name]}), reserved}
  end

  defp rpc(rpc, response_meta?, committed) do
    action = Info.action(rpc.resource, rpc.action)
    proto_name = Macro.camelize(Atom.to_string(rpc.name))

    {:ok, request_fields} = AshGrpc.Request.fields(rpc.resource, action, rpc)

    bulk_create? = rpc.bulk? and action.type == :create
    item_name = proto_name <> "Input"
    numbered_as = if bulk_create?, do: item_name, else: proto_name <> "Request"

    {request_fields, request_reserved} =
      number_request(rpc, numbered_as, request_fields, committed)

    {bulk_item, request_fields, request_reserved} =
      if bulk_create?,
        do:
          {%{name: item_name, fields: request_fields, reserved: request_reserved},
           [inputs_field(rpc, item_name)], []},
        else: {nil, request_fields, request_reserved}

    {:ok, result} = AshGrpc.Request.result(rpc.resource, action)

    many? =
      rpc.bulk? or result == :resources or AshGrpc.Request.many_read?(rpc.resource, action, rpc)

    page = for %{source: :page, name: name} <- request_fields, do: name

    %{
      name: rpc.name,
      proto_name: proto_name,
      resource: rpc.resource,
      action: rpc.action,
      action_type: action.type,
      result: if(match?({:value, _kind}, result), do: :value, else: result),
      description: action.description,
      read_action: record_read_action(rpc, action),
      many?: many?,
      paged?: page != [],
      stream?: rpc.stream?,
      streaming: rpc.streaming,
      max_stream_failures: AshGrpc.Request.max_stream_failures(rpc),
      stream_messages: stream_messages(rpc.streaming, proto_name),
      bulk_item: bulk_item,
      deprecated?: rpc.deprecated,
      load: rpc.load,
      request: %{
        name: proto_name <> "Request",
        fields: request_fields,
        reserved: request_reserved
      },
      response: %{
        name: proto_name <> "Response",
        fields:
          result_fields(result, rpc, action, many?) ++
            extra_fields(rpc, response_meta?) ++ page_fields(page),
        reserved: []
      }
    }
  end

  defp inputs_field(rpc, item_name) do
    %{
      name: :inputs,
      number: 1,
      kind: {:message, item_name},
      optional?: false,
      repeated?: true,
      source: :bulk_inputs,
      max_items: AshGrpc.Request.max_bulk_size(rpc)
    }
  end

  defp result_fields(:none, _rpc, _action, _many?), do: []

  defp result_fields({:value, kind}, _rpc, action, _many?),
    do: [AshGrpc.Types.put_kind(%{name: :result, number: 1, optional?: action.allow_nil?}, kind)]

  defp result_fields(_resource_result, rpc, _action, many?) do
    [
      %{
        name: :result,
        number: 1,
        kind: {:message, ResourceInfo.grpc_proto_message!(rpc.resource)},
        optional?: false,
        repeated?: many? and not rpc.stream?
      }
    ]
  end

  defp loads(_messages, _name, %{result: :value}), do: []

  defp loads(messages, name, rpc), do: message_loads(messages, name, rpc.load)

  defp message_loads(messages, name, load) do
    message = messages[name]
    scalars = for field <- message.fields, field[:load?], do: field.name

    relationships =
      for {relationship, nested} <- AshGrpc.Request.normalize_load(load) do
        field = Enum.find(message.fields, &(&1.name == relationship))
        {:message, destination} = field.kind

        case message_loads(messages, destination, nested) do
          [] -> relationship
          loads -> {relationship, loads}
        end
      end

    scalars ++ relationships
  end

  defp record_read_action(rpc, %{type: type}) when type in [:update, :destroy],
    do: rpc.read_action || Info.primary_action!(rpc.resource, :read).name

  defp record_read_action(_rpc, _action), do: nil

  defp extra_fields(%{streaming: streaming}, _response_meta?) when streaming != nil, do: []

  defp extra_fields(%{stream?: true}, _response_meta?),
    do: [
      %{name: :removed, number: 2, kind: :bool, optional?: false, repeated?: false},
      %{name: :synced, number: 3, kind: :bool, optional?: false, repeated?: false},
      %{name: :position, number: 4, kind: :uint32, optional?: true, repeated?: false}
    ]

  defp extra_fields(_rpc, true),
    do: [%{name: :meta, number: 2, kind: :string, optional?: true, repeated?: false}]

  defp extra_fields(_rpc, false), do: []

  defp stream_messages(nil, _proto_name), do: []

  defp stream_messages(:bidirectional, proto_name) do
    [
      message(proto_name <> "Reply", [
        field(:index, 1, :uint32),
        field(:result, 2, {:message, proto_name <> "Response"}, oneof: "outcome"),
        field(:error, 3, :rpc_status, oneof: "outcome")
      ])
    ]
  end

  defp stream_messages(:client, proto_name) do
    failure = proto_name <> "Failure"

    [
      message(proto_name <> "Summary", [
        field(:succeeded, 1, :uint32),
        field(:failures, 2, {:message, failure}, repeated?: true)
      ]),
      message(failure, [field(:index, 1, :uint32), field(:error, 2, :rpc_status)])
    ]
  end

  defp message(name, fields), do: %{name: name, resource: nil, fields: fields, reserved: []}

  defp field(name, number, kind, opts \\ []) do
    Map.merge(
      %{name: name, number: number, kind: kind, optional?: false, repeated?: false},
      Map.new(opts)
    )
  end

  defp page_fields([]), do: []

  defp page_fields(page) do
    keyset? = :after in page or :before in page

    [
      {:has_more, 3, :bool, false, true},
      {:count, 4, :int64, true, :count in page},
      {:first_keyset, 5, :string, true, keyset?},
      {:last_keyset, 6, :string, true, keyset?}
    ]
    |> Enum.filter(&elem(&1, 4))
    |> Enum.map(fn {name, number, kind, optional?, _sent?} ->
      %{
        name: name,
        number: number,
        kind: kind,
        optional?: optional?,
        repeated?: false,
        source: :page
      }
    end)
  end

  defp scalar_field(resource, name, number, deprecated) do
    field = ResourceInfo.field(resource, name)
    {:ok, kind} = AshGrpc.Types.kind(field.type, field.constraints)

    AshGrpc.Types.put_kind(
      %{
        name: name,
        number: number,
        optional?: field.allow_nil? or ResourceInfo.field_policy_covered?(resource, name),
        deprecated?: name in deprecated,
        description: field.description,
        load?: ResourceInfo.loaded?(field)
      },
      kind
    )
  end

  defp relationship_field(resource, relationship, number, deprecated) do
    destination = relationship.destination

    if !(match?({:module, _}, Code.ensure_compiled(destination)) and
           ResourceInfo.exposed?(destination)) do
      raise DslError,
        module: resource,
        path: [:grpc, :fields],
        message:
          "Field #{inspect(relationship.name)} of #{inspect(resource)} is a relationship to " <>
            "#{inspect(destination)}, which does not use `AshGrpc.Resource`. " <>
            "Add `extensions: [AshGrpc.Resource]` to #{inspect(destination)}."
    end

    kind =
      if relationship.cardinality == :many,
        do: {:array, {:resource, destination}},
        else: {:resource, destination}

    AshGrpc.Types.put_kind(
      %{
        name: relationship.name,
        number: number,
        optional?: true,
        deprecated?: relationship.name in deprecated,
        description: relationship.description,
        load?: false,
        relationship?: true
      },
      kind
    )
  end

  defp resource_message(resource, committed) do
    deprecated = ResourceInfo.grpc_deprecated!(resource)
    message_name = ResourceInfo.grpc_proto_message!(resource)

    {numbered, reserved} =
      AshGrpc.FieldNumbers.assign(
        resource,
        message_name,
        ResourceInfo.grpc_fields!(resource),
        ResourceInfo.grpc_reserved!(resource),
        committed
      )

    case deprecated -- Enum.map(numbered, &elem(&1, 0)) do
      [] ->
        :ok

      missing ->
        raise DslError,
          module: resource,
          path: [:grpc, :deprecated],
          message:
            "`deprecated` names #{inspect(missing)}, which are not sent in #{message_name}."
    end

    fields =
      for {name, number} <- numbered do
        case Info.relationship(resource, name) do
          nil -> scalar_field(resource, name, number, deprecated)
          relationship -> relationship_field(resource, relationship, number, deprecated)
        end
      end

    %{
      name: message_name,
      resource: resource,
      description: Info.description(resource),
      fields: fields,
      reserved: reserved
    }
  end
end
