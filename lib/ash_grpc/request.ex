defmodule AshGrpc.Request do
  @moduledoc false

  alias Ash.Resource.Info
  alias AshGrpc.Types

  @page_kinds [limit: :int64, offset: :int64, after: :string, before: :string, count: :bool]
  @page_needs [offset: :offset?, after: :keyset?, before: :keyset?, count: :countable]
  @field_kinds @page_kinds ++ [sort: :string, filter: :struct, clear_fields: :string]
  @default_max_bulk_size 100
  @default_max_stream_failures 100

  def fields(resource, action, rpc) do
    primary_key = Info.primary_key(resource)
    keyed? = keyed?(resource, action, rpc)
    build = &field(resource, action, primary_key, keyed?, &1)

    inputs =
      if rpc.args,
        do: Types.map_while_ok(Enum.map(rpc.args, &numbered/1), build),
        else: derived(resource, action, primary_key, build)

    with {:ok, fields} <- inputs,
         extras = extra_fields(resource, action, rpc),
         :ok <- verify_no_clash(fields, extras),
         {:ok, fields} <- bulk_keys(fields, primary_key, action, rpc) do
      {:ok, fields ++ extras}
    end
  end

  @doc false
  def bulk?(rpc, action), do: rpc.bulk? and action.type in [:create, :update, :destroy]

  @doc false
  def max_bulk_size(rpc), do: rpc.max_bulk_size || @default_max_bulk_size

  def max_stream_failures(rpc), do: rpc.max_stream_failures || @default_max_stream_failures

  defp bulk_keys(fields, primary_key, %{type: type} = action, rpc)
       when type in [:update, :destroy] do
    {keys, rest} = Enum.split_with(fields, &(&1.source == :primary_key))

    cond do
      not bulk?(rpc, action) ->
        {:ok, fields}

      Enum.any?(keys, & &1.argument?) ->
        names = for key <- keys, key.argument?, do: key.name

        {:error, "`bulk?` cannot take the primary key #{inspect(names)} as an action argument."}

      Enum.any?(rest, &(&1.name == :ids)) ->
        {:error,
         "`bulk?` uses the request field :ids for the primary key; rename the input named :ids."}

      true ->
        keys = Enum.sort_by(keys, &Enum.find_index(primary_key, fn name -> name == &1.name end))
        {:ok, [bulk_ids(keys, rpc) | rest]}
    end
  end

  defp bulk_keys(fields, _primary_key, _action, _rpc), do: {:ok, fields}

  defp bulk_ids(keys, rpc) do
    ids = %{
      name: :ids,
      number: hd(keys).number,
      source: :bulk_keys,
      optional?: false,
      repeated?: true,
      argument?: false,
      keys: keys,
      max_items: max_bulk_size(rpc)
    }

    case keys do
      [key] ->
        Map.merge(ids, %{kind: key.kind, description: key.description})

      _ ->
        key_fields =
          keys
          |> Enum.with_index(1)
          |> Enum.map(fn {key, number} -> %{key | number: number, optional?: false} end)

        Map.put(
          ids,
          :kind,
          {:fields, Macro.camelize(Atom.to_string(rpc.name)) <> "Key", key_fields}
        )
    end
  end

  @doc false
  def page_keys, do: Keyword.keys(@page_kinds)

  @doc false
  def allowed_page_keys(%{pagination: %{} = pagination}) do
    [:limit | for({key, flag} <- @page_needs, Map.get(pagination, flag), do: key)]
  end

  def allowed_page_keys(_action), do: []

  @doc false
  def page_entries(page) when is_list(page), do: Enum.map(page, &numbered/1)

  @doc false
  def many_read?(resource, action, rpc),
    do: action.type == :read and not action.get? and not keyed_read?(resource, action, rpc)

  @doc false
  def paged?(resource, action, rpc),
    do: Enum.any?(extra_fields(resource, action, rpc), &(&1.source == :page))

  defp verify_no_clash(fields, extras) do
    names = Enum.map(fields, & &1.name)

    case Enum.find(extras, &(&1[:default?] and &1.name in names)) do
      nil ->
        :ok

      extra ->
        {:error,
         "the input #{inspect(extra.name)} has the name of the field AshGrpc adds by default. " <>
           "Turn the default off with #{off_hint(extra)}."}
    end
  end

  defp off_hint(%{source: :page}), do: "`page: false`, or list the `page` names you want"
  defp off_hint(%{source: source}), do: "`#{source}: false`"

  defp numbered({name, number}), do: {name, number}
  defp numbered(name), do: {name, nil}

  defp derived(resource, action, primary_key, build) do
    names =
      Enum.uniq(
        if(action.type in [:update, :destroy], do: primary_key, else: []) ++
          if(action.type in [:create, :update, :destroy],
            do: Enum.filter(action.accept || [], &Info.attribute(resource, &1).public?),
            else: []
          ) ++
          for(argument <- action.arguments, argument.public?, do: argument.name)
      )

    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case build.({name, nil}) do
        {:ok, field} ->
          {:cont, {:ok, [field | acc]}}

        {:error, message} ->
          if required?(resource, action, primary_key, name),
            do:
              {:halt, {:error, message <> " The action requires it; list the inputs in `args:`."}},
            else: {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.reverse(fields)}
      error -> error
    end
  end

  defp required?(resource, action, primary_key, name) do
    argument = Enum.find(action.arguments, &(&1.name == name))

    cond do
      name in primary_key and action.type in [:update, :destroy] ->
        true

      argument ->
        not argument.allow_nil?

      true ->
        attribute = Info.attribute(resource, name)

        name in Map.get(action, :require_attributes, []) or
          (not attribute.allow_nil? and is_nil(attribute.default) and
             name not in Map.get(action, :allow_nil_input, []))
    end
  end

  defp field(resource, action, primary_key, keyed?, {name, number}) do
    with {:ok, source, type, constraints} <- source(resource, action, primary_key, name, keyed?),
         {:ok, kind} <- Types.field_kind(name, type, constraints) do
      {:ok,
       Types.put_kind(
         %{
           name: name,
           number: number,
           source: source,
           description: description(resource, action, name),
           type: type,
           constraints: constraints,
           argument?: Enum.any?(action.arguments, &(&1.name == name)),
           optional?: true
         },
         kind
       )}
    end
  end

  defp extra_fields(resource, action, rpc) do
    many? = many_read?(resource, action, rpc)

    options =
      page_options(rpc, action, many?) ++
        [
          {:sort, rpc.sort, many?},
          {:filter, rpc.filter, many?},
          {:clear_fields, rpc.clear_fields, action.type == :update and not rpc.bulk?}
        ]

    Enum.flat_map(options, &extra_field/1)
  end

  defp page_options(%{page: false}, _action, _many?), do: []
  defp page_options(%{page: nil, stream?: true}, _action, _many?), do: []

  defp page_options(%{page: nil}, action, many?),
    do: if(many?, do: for(key <- allowed_page_keys(action), do: {key, nil, true}), else: [])

  defp page_options(%{page: true}, action, _many?),
    do: for(key <- allowed_page_keys(action), do: {key, true, false})

  defp page_options(%{page: page}, _action, _many?),
    do:
      for(
        {key, number} <- page_entries(page),
        key in page_keys(),
        do: {key, number || true, false}
      )

  defp extra_field({_name, false, _default_on?}), do: []
  defp extra_field({_name, nil, false}), do: []
  defp extra_field({name, nil, true}), do: [build_extra(name, nil, true)]
  defp extra_field({name, true, _default_on?}), do: [build_extra(name, nil, false)]
  defp extra_field({name, number, _default_on?}), do: [build_extra(name, number, false)]

  defp build_extra(name, number, default?) do
    source = if name in page_keys(), do: :page, else: name

    %{
      name: name,
      number: number,
      kind: Keyword.fetch!(@field_kinds, name),
      source: source,
      optional?: source != :clear_fields,
      repeated?: source == :clear_fields,
      default?: default?
    }
  end

  @doc false
  def normalize_load(load) do
    for entry <- List.wrap(load) do
      case entry do
        {name, nested} -> {name, normalize_load(nested)}
        name -> {name, []}
      end
    end
  end

  @doc false
  def result(_resource, %{type: type}) when type != :action, do: {:ok, :resource}
  def result(_resource, %{returns: nil}), do: {:ok, :none}

  def result(resource, %{returns: returns, constraints: constraints}) do
    cond do
      own_struct?(resource, returns, constraints) ->
        {:ok, :resource}

      match?({:array, _}, returns) and
          own_struct?(resource, elem(returns, 1), constraints[:items] || []) ->
        {:ok, :resources}

      true ->
        with {:ok, kind} <- Types.kind(returns, constraints), do: {:ok, {:value, kind}}
    end
  end

  defp own_struct?(resource, type, constraints) do
    Ash.Type.get_type(type) == Ash.Type.Struct and constraints[:instance_of] == resource
  end

  def keyed_read?(resource, action, rpc) do
    action.type == :read and keyed?(resource, action, rpc)
  end

  defp keyed?(resource, action, rpc) do
    primary_key = Info.primary_key(resource)

    not rpc.stream? and rpc.args != nil and primary_key != [] and
      primary_key -- AshGrpc.FieldNumbers.names(rpc.args) == [] and
      Enum.all?(primary_key, &(not Enum.any?(action.arguments, fn a -> a.name == &1 end)))
  end

  defp description(resource, action, name) do
    argument = Enum.find(action.arguments, &(&1.name == name))
    attribute = Info.attribute(resource, name)
    (argument || attribute).description
  end

  defp source(resource, action, primary_key, name, keyed?) do
    argument = Enum.find(action.arguments, &(&1.name == name))
    attribute = Info.attribute(resource, name)

    cond do
      name in primary_key and
          (action.type in [:update, :destroy] or (action.type == :read and keyed?)) ->
        {:ok, :primary_key, attribute.type, attribute.constraints}

      argument ->
        {:ok, :argument, argument.type, argument.constraints}

      name in primary_key and action.type == :read ->
        {:error,
         "`args` lists only part of the primary key #{inspect(primary_key)} of a read; " <>
           "list every key field to look up one record."}

      action.type in [:create, :update, :destroy] and name in (action.accept || []) ->
        {:ok, :attribute, attribute.type, attribute.constraints}

      true ->
        {:error,
         "`args` names #{inspect(name)}, which is not an argument, accepted attribute " <>
           "or primary key of action #{inspect(action.name)}."}
    end
  end
end
