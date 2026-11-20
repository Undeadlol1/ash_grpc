defmodule AshGrpc.Handler do
  @moduledoc false

  alias Ash.Resource.Info
  alias AshGrpc.Types

  require Ash.Query

  @read [:page, :sort, :filter]
  @page_options [:limit, :offset, :after, :before, :count]
  @bulk [:bulk_inputs, :bulk_keys]
  @bulk_options [
    return_records?: true,
    return_errors?: true,
    transaction: :all,
    stop_on_error?: true,
    notify?: true
  ]

  def handle(spec, request, stream) do
    announce_compressor(stream)
    handle_call(spec, request, stream)
  end

  defp announce_compressor(%{compressor: nil}), do: :ok

  defp announce_compressor(%{compressor: compressor} = stream),
    do: GRPC.Server.set_compressor(stream, compressor)

  defp handle_call(%{stream?: true} = spec, request, stream),
    do: raise(subscribe(spec, request, stream))

  defp handle_call(%{streaming: :bidirectional} = spec, requests, stream) do
    each_message(spec, requests, stream, fn index, outcome ->
      GRPC.Server.send_reply(stream, struct(spec.reply_module, index: index, outcome: outcome))
    end)
  end

  defp handle_call(%{streaming: :client} = spec, requests, stream) do
    {succeeded, failures} =
      each_message(spec, requests, stream, {0, []}, fn
        _index, {:result, _reply}, {succeeded, failures} ->
          {succeeded + 1, failures}

        index, {:error, status}, {succeeded, failures} ->
          if length(failures) >= spec.max_stream_failures,
            do: raise(AshGrpc.Errors.to_rpc_error({:too_many_failures, spec.max_stream_failures}))

          {succeeded, [struct(spec.failure_module, index: index, error: status) | failures]}
      end)

    struct(spec.reply_module, succeeded: succeeded, failures: Enum.reverse(failures))
  end

  defp handle_call(spec, request, stream) do
    case call(spec, request, stream) do
      {:ok, reply} -> reply
      {:error, error} -> raise error
    end
  end

  defp each_message(spec, requests, stream, on_outcome) do
    each_message(spec, requests, stream, :ok, fn index, outcome, :ok ->
      on_outcome.(index, outcome)
      :ok
    end)
  end

  defp each_message(spec, requests, stream, initial, on_outcome) do
    {_count, acc} =
      Enum.reduce(requests, {0, initial}, fn request, {index, acc} ->
        if GRPC.Server.Stream.remaining_ms(stream) == 0,
          do: raise(AshGrpc.Errors.to_rpc_error(:deadline_exceeded))

        outcome =
          case call(spec, request, stream) do
            {:ok, reply} -> {:result, reply}
            {:error, error} -> {:error, AshGrpc.Errors.to_status(error)}
          end

        {index + 1, on_outcome.(index, outcome, acc)}
      end)

    acc
  end

  def log_exception?(%GRPC.Server.Adapters.ReportException{reason: %GRPC.RPCError{}}), do: false
  def log_exception?(_exception), do: true

  def ash_opts(auth_opts, stream) do
    opts =
      auth_opts |> Keyword.take([:actor, :tenant, :context]) |> Keyword.put(:authorize?, true)

    {opts, deadline(stream)}
  end

  defp deadline(stream) do
    case GRPC.Server.Stream.remaining_ms(stream) do
      :infinity -> []
      ms -> [timeout: ms]
    end
  end

  defp call(spec, request, stream) do
    with {:ok, auth_opts} <- authenticated(stream),
         {opts, _deadline} = ash_opts(auth_opts, stream),
         {:ok, decoded} <- input(spec, request),
         {:ok, result} <- run(spec, decoded, opts, stream),
         {result, page} = paged(spec, result),
         {:ok, result} <- found(spec, result),
         {:ok, result} <- load(spec, result, opts, stream),
         {:ok, encoded} <- encode(spec, result) do
      {:ok, reply(spec, encoded, page)}
    else
      {:error, error} -> {:error, AshGrpc.Errors.to_rpc_error(error)}
    end
  rescue
    error -> {:error, AshGrpc.Errors.internal(error, __STACKTRACE__)}
  end

  defp subscribe(spec, request, stream) do
    with_result =
      with {:ok, auth_opts} <- authenticated(stream),
           {opts, _deadline} = ash_opts(auth_opts, stream),
           {:ok, decoded} <- input(spec, request),
           :ok <- within_subscription_limit(spec.endpoint),
           :ok <- AshGrpc.Notifier.subscribe(spec.resource),
           subscription = %{spec: spec, decoded: decoded, opts: opts, stream: stream},
           {:ok, records} <- read_all(subscription),
           {:ok, found} <- encode_found(subscription, records) do
        sent = send_snapshot(subscription, found)
        send_synced(subscription)
        watch(subscription, sent)
      end

    then(with_result, fn {:error, error} -> AshGrpc.Errors.to_rpc_error(error) end)
  rescue
    error -> AshGrpc.Errors.internal(error, __STACKTRACE__)
  end

  defp within_subscription_limit(endpoint) do
    group = {:subscriptions, endpoint}
    :ok = :pg.join(AshGrpc.Notifier, group, self())
    limit = endpoint.__ash_grpc__(:max_subscriptions)

    if length(:pg.get_local_members(AshGrpc.Notifier, group)) > limit,
      do: {:error, {:too_many_subscriptions, limit}},
      else: :ok
  end

  defp watch(%{spec: %{resource: resource}} = subscription, sent) do
    receive do
      {AshGrpc.Notifier, ^resource, type, primary_key, tenant} ->
        with {:ok, sent} <- changed(subscription, type, primary_key, tenant, sent),
             do: watch(subscription, sent)
    after
      GRPC.Server.Stream.remaining_ms(subscription.stream) -> {:error, :deadline_exceeded}
    end
  end

  defp changed(subscription, type, primary_key, tenant, sent) do
    cond do
      Info.multitenancy_strategy(subscription.spec.resource) &&
          tenant != Ash.ToTenant.to_tenant(subscription.opts[:tenant], subscription.spec.resource) ->
        {:ok, sent}

      type == :destroy ->
        {:ok, removed(subscription, primary_key, sent)}

      true ->
        with {:ok, records} <- read_all(subscription) do
          case Enum.find_index(records, &(Map.take(&1, key_fields(subscription)) == primary_key)) do
            nil -> {:ok, removed(subscription, primary_key, sent)}
            position -> send_record(subscription, Enum.at(records, position), position, sent)
          end
        end
    end
  end

  defp key_fields(%{spec: spec}), do: Info.primary_key(spec.resource)

  defp read_all(%{spec: spec, decoded: decoded, opts: opts, stream: stream}),
    do: run(spec, decoded, opts, stream)

  defp encode_found(%{spec: spec, opts: opts, stream: stream} = subscription, records) do
    with {:ok, records} <- load(spec, records, opts, stream),
         {:ok, messages} <- encode(spec, records) do
      keys = Enum.map(records, &Map.take(&1, key_fields(subscription)))
      {:ok, Enum.zip(keys, messages)}
    end
  end

  defp send_snapshot(subscription, found) do
    found
    |> Enum.with_index()
    |> Enum.reduce(MapSet.new(), fn {{primary_key, message}, position}, sent ->
      send_change(subscription, message, false, position)
      MapSet.put(sent, primary_key)
    end)
  end

  defp send_record(subscription, record, position, sent) do
    with {:ok, [{primary_key, message}]} <- encode_found(subscription, [record]) do
      send_change(subscription, message, false, position)
      {:ok, MapSet.put(sent, primary_key)}
    end
  end

  defp removed(%{spec: spec} = subscription, primary_key, sent) do
    if MapSet.member?(sent, primary_key) do
      key_fields = Enum.filter(spec.message_fields, &Map.has_key?(primary_key, &1.name))
      {:ok, message} = message(%{spec | message_fields: key_fields}, primary_key)
      send_change(subscription, message, true, nil)
      MapSet.delete(sent, primary_key)
    else
      sent
    end
  end

  defp send_synced(%{spec: spec, stream: stream}) do
    GRPC.Server.send_reply(stream, struct(spec.response_module, synced: true))
  end

  defp send_change(%{spec: spec, stream: stream}, message, removed?, position) do
    GRPC.Server.send_reply(
      stream,
      struct(spec.response_module, result: message, removed: removed?, position: position)
    )
  end

  defp authenticated(stream) do
    with :error <- AshGrpc.Authenticator.fetch_opts(stream), do: {:error, :unauthenticated}
  end

  defp input(spec, request) do
    {clear, fields} = Enum.split_with(spec.request_fields, &(&1.source == :clear_fields))

    with {:ok, values} <- decode_fields(spec, fields, request),
         {:ok, cleared} <- cleared(clear, fields, values, request) do
      {read, values} = Enum.split_with(values, fn {field, _value} -> field.source in @read end)

      primary_key =
        for {%{source: :primary_key} = field, value} <- values, into: %{}, do: {field.name, value}

      input =
        for {field, value} <- values,
            field.source not in @bulk,
            field.source != :primary_key or field.argument?,
            into: cleared do
          {field.name, value}
        end

      read = Map.new(read, fn {field, value} -> {field.name, value} end)

      case Enum.find(
             spec.request_fields,
             &(&1.source == :primary_key and not is_map_key(primary_key, &1.name))
           ) do
        nil ->
          {:ok,
           Map.merge(%{primary_key: primary_key, input: input, read: read}, bulk(spec, values))}

        field ->
          {:error, Ash.Error.Changes.Required.exception(field: field.name, type: :argument)}
      end
    end
  end

  defp bulk(spec, values) do
    case Enum.find(spec.request_fields, &(&1.source in @bulk)) do
      nil ->
        %{}

      field ->
        %{
          bulk:
            {field.source,
             Enum.find_value(values, [], fn {sent, value} -> sent == field and value end)}
        }
    end
  end

  defp cleared([], _fields, _values, _request), do: {:ok, %{}}

  defp cleared([clear], fields, values, request) do
    sent = for {field, _value} <- values, do: field.name

    clearable =
      for field <- fields,
          field.source in [:argument, :attribute],
          field.name not in sent,
          into: %{} do
        {Atom.to_string(field.name), field.name}
      end

    Enum.reduce_while(Map.get(request, clear.name), {:ok, %{}}, fn name, {:ok, acc} ->
      case clearable do
        %{^name => field} ->
          {:cont, {:ok, Map.put(acc, field, nil)}}

        _ ->
          {:halt,
           {:error,
            invalid_argument(
              clear,
              "names #{inspect(name)}, which this request sets or cannot clear"
            )}}
      end
    end)
  end

  defp decode_fields(spec, fields, request) do
    case Types.decode_fields(fields, request, &decode(spec, &1, &2)) do
      {:ok, values} ->
        {:ok, values}

      {:error, field, {path, message}} ->
        {:error, invalid_argument(%{name: "#{field.name}#{path}"}, message)}

      {:error, field, message} ->
        {:error, invalid_argument(field, message)}
    end
  end

  defp decode(spec, %{source: :primary_key, type: type, constraints: constraints} = field, value) do
    with {:ok, wire} when not is_nil(wire) <- Types.decode_field(field, value, spec.messages),
         {:ok, cast} when not is_nil(cast) <- Ash.Type.cast_input(type, wire, constraints),
         {:ok, key} when not is_nil(key) <- Ash.Type.apply_constraints(type, cast, constraints) do
      {:ok, key}
    else
      _ -> {:error, "is invalid"}
    end
  end

  defp decode(spec, %{source: :bulk_inputs, kind: {:message, name}} = field, items) do
    with :ok <- within_limit(field, items) do
      fields = spec.messages[name].fields

      items
      |> Enum.with_index()
      |> Types.map_while_ok(fn {item, index} -> decode_item(spec, fields, item, index) end)
    end
  end

  defp decode(spec, %{source: :bulk_keys} = field, keys) do
    with :ok <- within_limit(field, keys),
         do: Types.map_while_ok(keys, &decode_key(spec, field.keys, &1))
  end

  defp decode(spec, field, value), do: Types.decode_field(field, value, spec.messages)

  defp within_limit(%{max_items: max}, items) when length(items) > max,
    do: {:error, "has more than #{max} items"}

  defp within_limit(_field, _items), do: :ok

  defp decode_item(spec, fields, item, index) do
    case Types.decode_fields(fields, item, &Types.decode_field(&1, &2, spec.messages)) do
      {:ok, values} -> {:ok, Map.new(values, fn {field, value} -> {field.name, value} end)}
      {:error, field, reason} -> {:error, {"[#{index}].#{field.name}", reason}}
    end
  end

  defp decode_key(spec, key_fields, value) do
    parts = if match?([_single], key_fields), do: %{hd(key_fields).name => value}, else: value

    with {:ok, pairs} <-
           Types.map_while_ok(key_fields, fn key ->
             with {:ok, cast} <- decode(spec, key, Map.get(parts, key.name)),
                  do: {:ok, {key.name, cast}}
           end) do
      {:ok, Map.new(pairs)}
    end
  end

  defp invalid_argument(field, message),
    do: Ash.Error.Changes.InvalidArgument.exception(field: field.name, message: message)

  defp get(spec, primary_key, loads, opts, stream) do
    with {:ok, filter} <- Ash.Filter.get_filter(spec.resource, primary_key) do
      spec.resource
      |> Ash.Query.for_read(spec.read_action, %{}, opts)
      |> Ash.Query.filter(^filter)
      |> Ash.Query.load(loads)
      |> Ash.read_one([not_found_error?: true] ++ deadline(stream))
    end
  end

  defp run(_spec, %{bulk: {_source, []}}, _opts, _stream), do: {:ok, []}

  defp run(spec, %{bulk: {:bulk_inputs, inputs}}, opts, stream) do
    inputs
    |> Ash.bulk_create(spec.resource, spec.action, opts ++ @bulk_options ++ deadline(stream))
    |> bulk_records(:inputs)
  end

  defp run(spec, %{bulk: {:bulk_keys, keys}, input: input}, opts, stream) do
    query =
      spec.resource
      |> Ash.Query.for_read(spec.read_action, %{}, opts)
      |> Ash.Query.do_filter(or: keys)

    options =
      [strategy: [:atomic, :atomic_batches, :stream]] ++ opts ++ @bulk_options ++ deadline(stream)

    case spec.action_type do
      :update -> query |> Ash.bulk_update(spec.action, input, options) |> bulk_records([])
      :destroy -> query |> Ash.bulk_destroy(spec.action, input, options) |> bulk_records([])
    end
  end

  defp run(%{action_type: :read, many?: true} = spec, decoded, opts, stream) do
    query =
      spec.resource
      |> Ash.Query.for_read(spec.action, decoded.input, opts)
      |> by_key(decoded.primary_key)

    page =
      if spec.paged?,
        do: [page: decoded.read |> Map.take(@page_options) |> Enum.to_list()],
        else: []

    with {:ok, query} <- read_input(spec, query, decoded.read, :sort, &Ash.Query.sort_input/2),
         {:ok, query} <-
           read_input(spec, query, decoded.read, :filter, &Ash.Query.filter_input/2) do
      Ash.read(query, page ++ deadline(stream))
    end
  end

  defp run(%{action_type: :read} = spec, %{input: input, primary_key: primary_key}, opts, stream) do
    spec.resource
    |> Ash.Query.for_read(spec.action, input, opts)
    |> by_key(primary_key)
    |> Ash.read_one([not_found_error?: true] ++ deadline(stream))
  end

  defp run(%{action_type: :create} = spec, %{input: input}, opts, stream) do
    spec.resource
    |> Ash.Changeset.for_create(spec.action, input, opts)
    |> Ash.create(deadline(stream))
  end

  defp run(
         %{action_type: :update} = spec,
         %{primary_key: primary_key, input: input},
         opts,
         stream
       ) do
    with {:ok, record} <- get(spec, primary_key, [], opts, stream) do
      record
      |> Ash.Changeset.for_update(spec.action, input, opts)
      |> Ash.update(deadline(stream))
    end
  end

  defp run(
         %{action_type: :destroy} = spec,
         %{primary_key: primary_key, input: input},
         opts,
         stream
       ) do
    with {:ok, record} <- get(spec, primary_key, spec.loads, opts, stream) do
      record
      |> Ash.Changeset.for_destroy(spec.action, input, opts)
      |> Ash.destroy([return_destroyed?: true] ++ deadline(stream))
    end
  end

  defp run(%{action_type: :action} = spec, %{input: input}, opts, stream) do
    run = fn ->
      case spec.resource
           |> Ash.ActionInput.for_action(spec.action, input, opts)
           |> Ash.run_action() do
        :ok -> {:ok, nil}
        other -> other
      end
    end

    Ash.ProcessHelpers.task_with_timeout(
      run,
      spec.resource,
      deadline(stream)[:timeout],
      spec.action,
      nil
    )
  end

  defp bulk_records(%Ash.BulkResult{status: :success, records: records}, _path),
    do: {:ok, records}

  defp bulk_records(%Ash.BulkResult{errors: errors}, path),
    do: {:error, Ash.Error.set_path(errors, path)}

  defp read_input(spec, query, read, name, apply) when is_map_key(read, name) do
    with nil <- unsent_field(spec, name, read[name]) do
      applied = apply.(query, read[name])

      case applied.errors -- query.errors do
        [] -> {:ok, applied}
        [error | _] -> {:error, invalid_argument(%{name: name}, Exception.message(error))}
      end
    else
      field ->
        {:error,
         invalid_argument(%{name: name}, "#{inspect(field)} is not a field this rpc sends")}
    end
  end

  defp read_input(_spec, query, _read, _name, _apply), do: {:ok, query}

  defp unsent_field(spec, :sort, sort) do
    sort
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("+") |> String.trim_leading("-")))
    |> Enum.find(&(&1 not in sent_names(spec.message_fields)))
  end

  defp unsent_field(spec, :filter, filter),
    do: unsent_in_filter(filter, spec.message_fields, spec.messages)

  defp unsent_in_filter(filter, fields, messages) when is_map(filter),
    do: Enum.find_value(filter, fn {key, value} -> unsent_key(key, value, fields, messages) end)

  defp unsent_in_filter(filters, fields, messages) when is_list(filters),
    do: Enum.find_value(filters, &unsent_in_filter(&1, fields, messages))

  defp unsent_in_filter(_value, _fields, _messages), do: nil

  defp unsent_key(key, value, fields, messages) when key in ["and", "or", "not"],
    do: unsent_in_filter(value, fields, messages)

  defp unsent_key(key, value, fields, messages) do
    case Enum.find(fields, &(Atom.to_string(&1.name) == key)) do
      nil -> key
      %{kind: {:message, name}} -> unsent_in_filter(value, messages[name].fields, messages)
      _scalar -> nil
    end
  end

  defp sent_names(fields), do: Enum.map(fields, &Atom.to_string(&1.name))

  defp by_key(query, primary_key) when primary_key == %{}, do: query

  defp by_key(query, primary_key) do
    {:ok, filter} = Ash.Filter.get_filter(query.resource, primary_key)
    Ash.Query.filter(query, ^filter)
  end

  defp found(%{many?: false, result: :resource} = spec, nil),
    do: {:error, Ash.Error.Query.NotFound.exception(resource: spec.resource)}

  defp found(_spec, result), do: {:ok, result}

  defp load(%{action_type: :destroy}, result, _opts, _stream), do: {:ok, result}
  defp load(%{loads: []}, result, _opts, _stream), do: {:ok, result}

  defp load(spec, result, opts, stream) do
    Ash.ProcessHelpers.task_with_timeout(
      fn -> Ash.load(result, spec.loads, [lazy?: true] ++ opts) end,
      spec.resource,
      deadline(stream)[:timeout],
      spec.action,
      nil
    )
  end

  defp paged(%{paged?: false}, result), do: {result, %{}}

  defp paged(spec, %page_type{results: records} = page)
       when page_type in [Ash.Page.Offset, Ash.Page.Keyset],
       do: {records, page_reply(spec, records, page.more?, page.count)}

  defp paged(spec, records), do: {records, page_reply(spec, records, false, nil)}

  defp page_reply(spec, records, more?, count) do
    Map.take(
      %{
        has_more: more?,
        count: count,
        first_keyset: keyset(List.first(records)),
        last_keyset: keyset(List.last(records))
      },
      spec.page_fields
    )
  end

  defp keyset(nil), do: nil
  defp keyset(record), do: record.__metadata__[:keyset]

  defp reply(%{streaming: :client}, _encoded, _page), do: :saved

  defp reply(spec, encoded, page) do
    response = struct(spec.response_module, Map.put(page, :result, encoded))

    if spec.response_meta?,
      do: %{response | meta: AshGrpc.Endpoint.take_response_meta()},
      else: response
  end

  defp encode(%{result: :none}, _value), do: {:ok, nil}

  defp encode(%{result: :value} = spec, value),
    do: {:ok, Types.encode_field(spec.result_field, value, spec.messages)}

  defp encode(%{many?: true} = spec, records) do
    Types.map_while_ok(records, &message(spec, &1))
  end

  defp encode(spec, record), do: message(spec, record)

  defp message(spec, record) do
    Types.encode_message(spec.message_module, spec.message_fields, record, spec.messages)
  end
end
