defmodule AshGrpc.Types do
  @moduledoc """
  The Ash types that have a protobuf mapping, and how values cross the wire.

  | Ash type | protobuf |
  |---|---|
  | string, ci_string, uuid, uuid_v7 | `string` |
  | atom | `string` (the name) |
  | `Ash.Type.Enum`; atom with `one_of` | an `enum` |
  | map | `google.protobuf.Struct` |
  | `{:array, type}` | `repeated`; nil is sent as empty, an empty request list is "not sent" |
  | integer | `int64` |
  | float | `double` |
  | boolean | `bool` |
  | utc_datetime, utc_datetime_usec, datetime | `google.protobuf.Timestamp` |
  | date, time, time_usec, naive_datetime, duration | `string` (ISO 8601) |
  | decimal | `string` |
  | binary | `bytes` |
  | url_encoded_binary | `string` (unpadded URL-safe base64) |
  | embedded resource with a `grpc` block | its message |
  | typed struct; map, keyword, struct or tuple with `fields` | a nested message |
  | `{:array, {:array, type}}` | `repeated` of a wrapper message with `repeated type values = 1` |
  | union | a nested message with one `oneof` of its types |

  A `NewType` is mapped as the type it is a subtype of; a nested message or
  enum from one is named after its module's last part. An enum has
  `<PREFIX>_UNSPECIFIED = 0` and then one value per Ash value, numbered from 1
  in the order of `values/0`.
  A map is JSON on the wire: atoms become strings, and every number is a
  `double`, so integers above 2^53 lose precision.

  Every other type is rejected at compile time, with the reason.
  """

  alias Ash.Resource.Info
  alias Ash.Type.NewType
  alias Google.Protobuf.Struct
  alias Google.Protobuf.Timestamp
  alias Google.Protobuf.Value

  @kinds %{
    Ash.Type.String => :string,
    Ash.Type.CiString => :string,
    Ash.Type.UUID => :string,
    Ash.Type.UUIDv7 => :string,
    Ash.Type.Atom => :atom,
    Ash.Type.Integer => :int64,
    Ash.Type.Float => :double,
    Ash.Type.Boolean => :bool,
    Ash.Type.UtcDatetime => :timestamp,
    Ash.Type.UtcDatetimeUsec => :timestamp,
    Ash.Type.DateTime => :timestamp,
    Ash.Type.Date => :date,
    Ash.Type.Time => :time,
    Ash.Type.TimeUsec => :time,
    Ash.Type.NaiveDatetime => :naive_datetime,
    Ash.Type.Duration => :duration,
    Ash.Type.Decimal => :decimal,
    Ash.Type.Binary => :bytes,
    Ash.Type.UrlEncodedBinary => :base64,
    Ash.Type.Map => :struct
  }

  @rejected %{
    Ash.Type.Term => "can hold any term, which has no protobuf shape",
    Ash.Type.Function => "is a function, which cannot cross the wire",
    Ash.Type.Module => "is a module name, which clients cannot send without creating atoms",
    Ash.Type.Vector => "is a vector; use `{:array, :float}`",
    Ash.Type.File => "is a file; use `:binary`",
    Ash.Type.Range => "is a range, which has no protobuf shape",
    Ash.Type.Struct => "is a struct without `fields` constraints or an embedded `instance_of`",
    Ash.Type.Keyword => "is a keyword list without `fields` constraints"
  }

  @strings [:string, :atom, :date, :time, :naive_datetime, :duration, :decimal, :base64]

  @type kind ::
          {:array, kind()}
          | {:fields, String.t() | nil, [map()]}
          | {:tuple, String.t() | nil, [map()]}
          | {:wrapper, kind()}
          | {:union, String.t() | nil, [map()]}
          | {:resource, module()}
          | {:enum,
             %{name: String.t() | nil, values: [%{value: atom(), description: String.t() | nil}]}}
          | :string
          | :atom
          | :int64
          | :double
          | :bool
          | :bytes
          | :base64
          | :timestamp
          | :date
          | :time
          | :naive_datetime
          | :duration
          | :decimal
          | :struct
          | :rpc_status
          | :uint32

  @doc "The wire kind of an Ash type, or why it has no mapping."
  @spec kind(term(), keyword()) :: {:ok, kind()} | {:error, String.t()}
  def kind(type, constraints \\ [])

  def kind(type, constraints) when is_atom(type) do
    type = Ash.Type.get_type(type)

    cond do
      type in [Ash.Type.Map, Ash.Type.Keyword, Ash.Type.Struct] and constraints[:fields] ->
        fields_kind(nil, constraints[:fields])

      type == Ash.Type.Struct and embedded?(constraints[:instance_of]) ->
        resource_kind(constraints[:instance_of])

      type == Ash.Type.Tuple ->
        tuple_kind(nil, constraints[:fields])

      type == Ash.Type.Union ->
        union_kind(constraints[:types] || [])

      type == Ash.Type.Atom and constraints[:one_of] ->
        enum_kind(nil, constraints[:one_of], fn _value -> nil end)

      is_map_key(@kinds, type) ->
        Map.fetch(@kinds, type)

      NewType.new_type?(type) ->
        new_type_kind(type, constraints)

      Spark.implements_behaviour?(type, Ash.Type.Enum) ->
        enum_kind(last_part(type), type.values(), &type.description/1)

      embedded?(type) ->
        resource_kind(type)

      is_map_key(@rejected, type) ->
        {:error, Map.fetch!(@rejected, type)}

      true ->
        {:error, "is not a type AshGrpc knows how to send"}
    end
  end

  def kind({:array, type}, constraints) do
    with {:ok, kind} <- kind(type, Keyword.get(constraints, :items, [])) do
      cond do
        constraints[:nil_items?] ->
          {:error, "is an array that allows nil items, which protobuf cannot express"}

        match?({:array, _kind}, kind) ->
          {:ok, {:array, {:wrapper, elem(kind, 1)}}}

        true ->
          {:ok, {:array, kind}}
      end
    end
  end

  def kind(_type, _constraints), do: {:error, "is not a type AshGrpc knows how to send"}

  defp embedded?(type) do
    is_atom(type) and type != nil and match?({:module, _}, Code.ensure_compiled(type)) and
      Info.resource?(type) and Info.embedded?(type)
  end

  defp resource_kind(resource) do
    cond do
      not AshGrpc.Resource.Info.exposed?(resource) ->
        {:error,
         "is the embedded resource #{inspect(resource)}, which does not use `AshGrpc.Resource`. " <>
           "Add `extensions: [AshGrpc.Resource]` to it"}

      Enum.any?(
        AshGrpc.FieldNumbers.names(AshGrpc.Resource.Info.listed_fields(resource) || []),
        fn name ->
          Info.calculation(resource, name)
        end
      ) ->
        {:error,
         "is the embedded resource #{inspect(resource)}, whose grpc `fields` include a calculation, " <>
           "which is not loaded inside another record"}

      true ->
        {:ok, {:resource, resource}}
    end
  end

  defp enum_kind(name, values, describe) do
    values = for value <- values, do: %{value: value, description: describe.(value)}
    proto_names = Enum.map(values, &value_name(&1.value))

    cond do
      bad =
          Enum.find(values, &(not Regex.match?(~r/^[A-Za-z][A-Za-z0-9_]*$/, to_string(&1.value)))) ->
        {:error,
         "has the enum value #{inspect(bad.value)}, which is not a protobuf name " <>
           "(letters, digits and underscores, starting with a letter)"}

      duplicate = Enum.find(proto_names, &(Enum.count(proto_names, fn n -> n == &1 end) > 1)) ->
        {:error, "has enum values that are all named #{duplicate} in protobuf"}

      true ->
        {:ok, {:enum, %{name: name, values: values}}}
    end
  end

  defp value_name(value), do: value |> to_string() |> Macro.underscore() |> String.upcase()

  @doc """
  The protobuf values of an enum named `name`: `<PREFIX>_UNSPECIFIED = 0`, then
  one per Ash value numbered from 1.
  """
  @spec enum_values(String.t(), [%{value: atom(), description: String.t() | nil}]) :: [map()]
  def enum_values(name, values) do
    prefix = name |> Macro.underscore() |> String.upcase()

    [%{value: nil, name: prefix <> "_UNSPECIFIED", number: 0, description: nil}] ++
      for {%{value: value} = entry, number} <- Enum.with_index(values, 1) do
        Map.merge(entry, %{name: prefix <> "_" <> value_name(value), number: number})
      end
  end

  defp union_kind([]), do: {:error, "is a union without types"}

  defp union_kind(types) do
    members =
      for {name, opts} <- types do
        {name, [type: opts[:type], constraints: opts[:constraints] || [], allow_nil?: false]}
      end

    with {:ok, {:fields, nil, members}} <- fields_kind(nil, members, "member") do
      case Enum.find(members, & &1.repeated?) do
        nil ->
          {:ok, {:union, nil, members}}

        member ->
          {:error,
           "has a member #{inspect(member.name)} that is an array, which a protobuf oneof cannot hold"}
      end
    end
  end

  defp tuple_kind(_name, nil), do: {:error, "is a tuple without `fields` constraints"}

  defp tuple_kind(name, fields) do
    with {:ok, {:fields, _name, fields}} <- fields_kind(name, fields) do
      {:ok, {:tuple, name, fields}}
    end
  end

  defp fields_kind(name, fields, noun \\ "field") do
    fields
    |> Enum.with_index(1)
    |> map_while_ok(fn {{field_name, opts}, number} ->
      case kind(opts[:type], opts[:constraints] || []) do
        {:ok, kind} ->
          field = %{
            name: field_name,
            number: number,
            optional?: Keyword.get(opts, :allow_nil?, true)
          }

          {:ok, put_kind(field, kind)}

        {:error, reason} ->
          {:error, "has a #{noun} #{inspect(field_name)} that #{reason}"}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, {:fields, name, fields}}
      error -> error
    end
  end

  @doc false
  def map_while_ok(enumerable, fun) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp new_type_kind(type, constraints) do
    case Ash.Type.init(type, constraints) do
      {:ok, constraints} ->
        type
        |> NewType.subtype_of()
        |> kind(NewType.constraints(type, constraints))
        |> named(type)

      {:error, _error} ->
        {:error, "has constraints that do not initialize"}
    end
  end

  defp named({:ok, {:fields, nil, fields}}, new_type),
    do: {:ok, {:fields, last_part(new_type), fields}}

  defp named({:ok, {:tuple, nil, fields}}, new_type),
    do: {:ok, {:tuple, last_part(new_type), fields}}

  defp named({:ok, {:union, nil, members}}, new_type),
    do: {:ok, {:union, last_part(new_type), members}}

  defp named({:ok, {:enum, enum}}, new_type),
    do: {:ok, {:enum, %{enum | name: last_part(new_type)}}}

  defp named(result, _new_type), do: result

  defp last_part(module), do: module |> Module.split() |> List.last()

  @doc false
  def put_kind(field, {:array, kind}), do: Map.merge(field, %{kind: kind, repeated?: true})
  def put_kind(field, kind), do: Map.merge(field, %{kind: kind, repeated?: false})

  @doc false
  def encode_message(module, fields, record, messages) do
    {:ok, build_message(module, fields, record, messages)}
  end

  defp message_record(:tuple, fields, tuple),
    do: fields |> Enum.map(& &1.name) |> Enum.zip(Tuple.to_list(tuple)) |> Map.new()

  defp message_record(:list, _fields, list), do: %{values: list}
  defp message_record(nil, _fields, value), do: value

  defp build_message(module, fields, record, messages) do
    record = if is_list(record), do: Map.new(record), else: record

    values =
      Enum.flat_map(fields, fn field ->
        case field_value(record, field.name) do
          %Ash.ForbiddenField{} -> []
          %Ash.NotLoaded{} -> []
          value -> [{field.name, encode_field(field, value, messages)}]
        end
      end)

    struct(module, values)
  end

  defp field_value(record, name) do
    case Map.fetch(record, name) do
      {:ok, value} -> value
      :error -> Map.get(record, Atom.to_string(name))
    end
  end

  @doc false
  def encode_field(%{repeated?: true, kind: kind}, values, messages),
    do: Enum.map(List.wrap(values), &encode_value(kind, &1, messages))

  def encode_field(field, value, messages), do: encode_value(field.kind, value, messages)

  defp encode_value({:message, _name}, %Ash.Union{value: nil}, _messages), do: nil

  defp encode_value({:message, name}, value, messages) when not is_nil(value) do
    case Map.fetch!(messages, name) do
      %{oneof?: true, module: module, fields: members} ->
        %Ash.Union{type: type, value: inner} = value
        member = Enum.find(members, &(&1.name == type))
        struct(module, value: {type, encode_value(member.kind, inner, messages)})

      %{module: module, fields: fields} = message ->
        build_message(module, fields, message_record(message[:shape], fields, value), messages)
    end
  end

  defp encode_value({:enum_type, name}, value, messages) when not is_nil(value),
    do: Map.fetch!(Map.fetch!(messages, name).to_proto, value)

  defp encode_value(kind, value, _messages), do: encode(kind, value)

  @doc false
  def decode_fields(fields, message, decode) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
      with value when value not in [nil, []] <- Map.get(message, field.name),
           {:ok, decoded} when not is_nil(decoded) <- decode.(field, value) do
        {:cont, {:ok, [{field, decoded} | acc]}}
      else
        empty when empty in [nil, [], {:ok, nil}] -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, field, reason}}
      end
    end)
  end

  @doc false
  def decode_field(%{repeated?: true, kind: kind}, values, messages) do
    with {:ok, decoded} <- map_while_ok(values, &decode_value(kind, &1, messages)) do
      if Enum.member?(decoded, nil),
        do: {:error, "has an unspecified value in its list"},
        else: {:ok, decoded}
    end
  end

  def decode_field(field, value, messages), do: decode_value(field.kind, value, messages)

  defp decode_value({:message, name}, message, messages) do
    case Map.fetch!(messages, name) do
      %{oneof?: true, fields: members} ->
        decode_union(members, message.value, messages)

      %{fields: fields} = definition ->
        case decode_fields(fields, message, &decode_field(&1, &2, messages)) do
          {:ok, values} ->
            {:ok,
             shape_value(
               definition[:shape],
               fields,
               Map.new(values, fn {field, value} -> {field.name, value} end)
             )}

          {:error, field, reason} ->
            {:error, "#{field.name} #{reason}"}
        end
    end
  end

  defp decode_value({:enum_type, name}, value, messages) do
    enum = Map.fetch!(messages, name)

    case enum.from_proto do
      %{^value => ash_value} -> {:ok, ash_value}
      _ -> {:error, "is not a known #{name}"}
    end
  end

  defp decode_value(kind, value, _messages), do: decode(kind, value)

  defp shape_value(:tuple, fields, map),
    do: fields |> Enum.map(&Map.get(map, &1.name)) |> List.to_tuple()

  defp shape_value(:list, _fields, map), do: Map.get(map, :values, [])
  defp shape_value(nil, _fields, map), do: map

  defp decode_union(_members, nil, _messages), do: {:ok, nil}

  defp decode_union(members, {type, value}, messages) do
    member = Enum.find(members, &(&1.name == type))

    case decode_field(member, value, messages) do
      {:ok, decoded} -> {:ok, %Ash.Union{type: type, value: decoded}}
      {:error, reason} -> {:error, "#{type} #{reason}"}
    end
  end

  @doc false
  def field_kind(name, type, constraints) do
    case kind(type, constraints) do
      {:ok, kind} ->
        {:ok, kind}

      {:error, reason} ->
        {:error,
         "Field #{inspect(name)} has type #{inspect(type)}, which has no protobuf mapping: it #{reason}."}
    end
  end

  @doc "The protobuf type name of a kind, as written in a `.proto` file."
  @spec proto_type(kind() | {:message, String.t()} | {:enum_type, String.t()}) :: String.t()
  def proto_type({:message, name}), do: name
  def proto_type({:enum_type, name}), do: name
  def proto_type(:timestamp), do: "google.protobuf.Timestamp"
  def proto_type(:struct), do: "google.protobuf.Struct"
  def proto_type(:rpc_status), do: "google.rpc.Status"
  def proto_type(kind) when kind in @strings, do: "string"
  def proto_type(kind), do: Atom.to_string(kind)

  @doc "The `type:` option for a `Protobuf` field of this kind."
  @spec field_type(kind()) :: atom()
  def field_type(:timestamp), do: Timestamp
  def field_type(:struct), do: Struct
  def field_type(:rpc_status), do: AshGrpc.Status
  def field_type(kind) when kind in @strings, do: :string
  def field_type(kind), do: kind

  @doc "Whether the kind is a message type, which has presence without `optional`."
  @spec message?(kind() | {:message, String.t()}) :: boolean()
  def message?({:message, _name}), do: true
  def message?(kind), do: kind in [:timestamp, :struct, :rpc_status]

  @doc "An Ash value as the protobuf value."
  @spec encode(kind(), term()) :: term()
  def encode(_kind, nil), do: nil
  def encode(:timestamp, %DateTime{} = value), do: timestamp(value)
  def encode(:date, %Date{} = value), do: Date.to_iso8601(value)
  def encode(:time, %Time{} = value), do: Time.to_iso8601(value)
  def encode(:naive_datetime, %NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def encode(:duration, %Duration{} = value), do: Duration.to_iso8601(value)
  def encode(:base64, value) when is_binary(value), do: Base.url_encode64(value, padding: false)
  def encode(:decimal, %Decimal{} = value), do: Decimal.to_string(value)

  def encode(:struct, value) when is_map(value),
    do: value |> Jason.encode!() |> Jason.decode!() |> to_struct()

  def encode(:atom, value) when is_atom(value), do: Atom.to_string(value)
  def encode(:double, value) when is_integer(value), do: value * 1.0
  def encode(_kind, value), do: value

  @doc "A protobuf value as Ash input, or why it is malformed; Ash casts the rest."
  @spec decode(kind(), term()) :: {:ok, term()} | {:error, String.t()}
  def decode(:timestamp, %Timestamp{seconds: seconds, nanos: nanos})
      when nanos in 0..999_999_999 do
    case DateTime.from_unix(seconds * 1_000_000_000 + nanos, :nanosecond) do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, "is not a representable timestamp"}
    end
  end

  def decode(:timestamp, %Timestamp{}), do: {:error, "has nanos out of range"}

  def decode(:struct, %Struct{fields: fields}),
    do: {:ok, Map.new(fields, fn {key, value} -> {key, from_value(value)} end)}

  def decode(_kind, value), do: {:ok, value}

  defp to_struct(map), do: %Struct{fields: Map.new(map, fn {k, v} -> {k, to_value(v)} end)}

  defp to_value(nil), do: %Value{kind: {:null_value, :NULL_VALUE}}

  defp to_value(value) when is_boolean(value), do: %Value{kind: {:bool_value, value}}

  defp to_value(value) when is_number(value), do: %Value{kind: {:number_value, value * 1.0}}

  defp to_value(value) when is_binary(value), do: %Value{kind: {:string_value, value}}

  defp to_value(value) when is_list(value),
    do: %Value{
      kind: {:list_value, %Google.Protobuf.ListValue{values: Enum.map(value, &to_value/1)}}
    }

  defp to_value(value) when is_map(value), do: %Value{kind: {:struct_value, to_struct(value)}}

  defp from_value(%Value{kind: {:struct_value, struct}}), do: elem(decode(:struct, struct), 1)

  defp from_value(%Value{kind: {:list_value, list}}), do: Enum.map(list.values, &from_value/1)

  defp from_value(%Value{kind: {:number_value, number}}), do: whole_or_float(number)

  defp from_value(%Value{kind: {:null_value, _null}}), do: nil
  defp from_value(%Value{kind: {_tag, value}}), do: value
  defp from_value(%Value{kind: nil}), do: nil

  defp whole_or_float(number) when number == trunc(number) and abs(number) < 9.0e15,
    do: trunc(number)

  defp whole_or_float(number), do: number

  defp timestamp(value) do
    nanoseconds = DateTime.to_unix(value, :nanosecond)

    %Timestamp{
      seconds: Integer.floor_div(nanoseconds, 1_000_000_000),
      nanos: Integer.mod(nanoseconds, 1_000_000_000)
    }
  end
end
