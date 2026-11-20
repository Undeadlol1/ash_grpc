defmodule AshGrpc.Domain.Verifiers.ValidateRpcs do
  @moduledoc false

  # A verifier only warns on domain compilation, since the domain cannot wait for
  # its resources; AshGrpc.Schema.build/2 runs it again and raises.

  use Spark.Dsl.Verifier

  alias AshGrpc.FieldNumbers
  alias AshGrpc.Resource.Info
  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    services = Verifier.get_entities(dsl_state, [:grpc])

    rpcs = for service <- services, rpc <- service.rpcs ++ service.subscriptions, do: rpc

    with :ok <- verify_unique(module, "Service names", Enum.map(services, & &1.name)),
         :ok <- verify_unique(module, "Rpc names", Enum.map(rpcs, & &1.name)),
         do: Enum.find_value(rpcs, :ok, &(module |> verify_rpc(&1) |> if_error()))
  end

  defp if_error(:ok), do: nil
  defp if_error(error), do: error

  defp verify_unique(module, label, names) do
    case Enum.uniq(names -- Enum.uniq(names)) do
      [] ->
        :ok

      duplicates ->
        FieldNumbers.error(module, [:grpc], "#{label} repeat: #{inspect(duplicates)}.")
    end
  end

  defp verify_rpc(module, rpc) do
    path = [:grpc, :service, if(rpc.stream?, do: :subscription, else: :rpc), rpc.name]

    with :ok <- verify_resource(module, path, rpc),
         {:ok, action} <- verify_action(module, path, rpc),
         :ok <- verify_subscription(module, path, rpc, action),
         :ok <- verify_streaming(module, path, rpc, action),
         :ok <- verify_bulk(module, path, rpc, action),
         :ok <- verify_read_options(module, path, rpc, action),
         :ok <- FieldNumbers.validate(rpc.args || [], module, path),
         :ok <- verify_clear_fields(module, path, rpc),
         :ok <- verify_load(module, path, rpc, action),
         :ok <- verify_primary_key(module, path, rpc, action),
         :ok <- verify_read_action(module, path, rpc, action) do
      case AshGrpc.Request.fields(rpc.resource, action, rpc) do
        {:ok, fields} ->
          numbered = Enum.map(fields, &if(&1.number, do: {&1.name, &1.number}, else: &1.name))
          numbers = for %{number: number} <- fields, number, do: number

          with :ok <- FieldNumbers.validate(numbered, module, path) do
            FieldNumbers.validate_reserved(
              rpc.reserved,
              numbers,
              module,
              path,
              "#{label(rpc)}: "
            )
          end

        {:error, message} ->
          FieldNumbers.error(module, path, "#{label(rpc)}: " <> message)
      end
    end
  end

  defp verify_streaming(module, path, %{streaming: nil} = rpc, _action) do
    if rpc.max_stream_failures,
      do:
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: `max_stream_failures` only applies with `streaming: :client`."
        ),
      else: :ok
  end

  defp verify_streaming(module, path, %{bulk?: true} = rpc, _action),
    do:
      FieldNumbers.error(
        module,
        path,
        "#{label(rpc)}: `streaming` cannot be combined with `bulk?`."
      )

  defp verify_streaming(
         module,
         path,
         %{streaming: :bidirectional, max_stream_failures: failures} = rpc,
         _action
       )
       when not is_nil(failures),
       do:
         FieldNumbers.error(
           module,
           path,
           "#{label(rpc)}: `max_stream_failures` only applies with `streaming: :client`."
         )

  defp verify_streaming(module, path, %{streaming: :client} = rpc, %{type: :read}) do
    FieldNumbers.error(
      module,
      path,
      "#{label(rpc)}: `streaming: :client` needs an action that writes; #{inspect(rpc.action)} is a read action."
    )
  end

  defp verify_streaming(_module, _path, _rpc, _action), do: :ok

  defp verify_bulk(module, path, %{bulk?: false} = rpc, _action) do
    if rpc.max_bulk_size,
      do:
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: `max_bulk_size` only applies with `bulk?: true`."
        ),
      else: :ok
  end

  defp verify_bulk(module, path, rpc, %{type: type})
       when type not in [:create, :update, :destroy] do
    FieldNumbers.error(
      module,
      path,
      "#{label(rpc)}: `bulk?` needs a create, update or destroy action; #{inspect(rpc.action)} has type #{inspect(type)}."
    )
  end

  defp verify_bulk(module, path, rpc, _action) do
    case Enum.find([:clear_fields, :page, :sort, :filter], &(rpc |> Map.fetch!(&1) |> asked?())) do
      nil ->
        :ok

      option ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: `bulk?` cannot be combined with `#{option}`."
        )
    end
  end

  defp verify_read_options(module, path, rpc, action) do
    asked = for name <- [:page, :sort, :filter], rpc |> Map.fetch!(name) |> asked?(), do: name

    cond do
      asked != [] and not AshGrpc.Request.many_read?(rpc.resource, action, rpc) ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: `page`, `sort` and `filter` need a read action that returns many; " <>
            "#{inspect(rpc.action)} does not."
        )

      :page not in asked ->
        :ok

      action.pagination == false ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: `page` needs a read action with `pagination`; #{inspect(rpc.action)} has none."
        )

      is_list(rpc.page) ->
        verify_page_keys(module, path, rpc, action)

      true ->
        :ok
    end
  end

  defp asked?(option), do: option not in [nil, false]

  defp verify_page_keys(module, path, rpc, action) do
    keys = rpc.page |> AshGrpc.Request.page_entries() |> Keyword.keys()
    unknown = keys -- AshGrpc.Request.page_keys()
    refused = keys -- AshGrpc.Request.allowed_page_keys(action)

    cond do
      unknown != [] ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: `page` lists #{inspect(unknown)}; the keys are #{inspect(AshGrpc.Request.page_keys())}."
        )

      :limit not in keys ->
        FieldNumbers.error(module, path, "#{label(rpc)}: `page` needs `:limit`.")

      refused != [] ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: `page` lists #{inspect(refused)}, which read action #{inspect(rpc.action)} does not allow."
        )

      true ->
        :ok
    end
  end

  defp label(%{stream?: true, name: name}), do: "subscription #{inspect(name)}"
  defp label(rpc), do: "rpc #{inspect(rpc.name)}"

  defp verify_subscription(_module, _path, %{stream?: false}, _action), do: :ok

  defp verify_subscription(module, path, rpc, action) do
    primary_key = Ash.Resource.Info.primary_key(rpc.resource)

    cond do
      action.type != :read ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: action #{inspect(rpc.action)} is not a read action."
        )

      primary_key -- Info.grpc_field_names(rpc.resource) != [] ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: the primary key #{inspect(primary_key)} must be in the resource's grpc `fields`, " <>
            "since a removed record is sent as its primary key."
        )

      true ->
        :ok
    end
  end

  defp verify_load(_module, _path, %{load: []}, _action), do: :ok

  defp verify_load(module, path, rpc, action) do
    if AshGrpc.Request.result(rpc.resource, action) in [{:ok, :resource}, {:ok, :resources}] do
      check_load(module, path, rpc, rpc.resource, AshGrpc.Request.normalize_load(rpc.load))
    else
      FieldNumbers.error(
        module,
        path,
        "#{label(rpc)}: `load` needs an action that returns #{inspect(rpc.resource)} records."
      )
    end
  end

  defp check_load(module, path, rpc, resource, load) do
    Enum.find_value(load, :ok, fn {name, nested} ->
      with {:ok, destination} <- load_destination(resource, name),
           :ok <- check_load(module, path, rpc, destination, nested) do
        nil
      else
        {:error, reason} when is_binary(reason) ->
          FieldNumbers.error(module, path, "#{label(rpc)}: `load` #{reason}")

        error ->
          error
      end
    end)
  end

  defp load_destination(resource, name) do
    relationship = Ash.Resource.Info.relationship(resource, name)

    cond do
      relationship == nil ->
        {:error, "names #{inspect(name)}, which is not a relationship of #{inspect(resource)}."}

      name not in Info.grpc_field_names(resource) ->
        {:error,
         "names the relationship #{inspect(name)}, which is not in the grpc `fields` of #{inspect(resource)}."}

      not (match?({:module, _}, Code.ensure_compiled(relationship.destination)) and
               Info.exposed?(relationship.destination)) ->
        {:error,
         "names #{inspect(name)}, whose resource #{inspect(relationship.destination)} does not use `AshGrpc.Resource`."}

      true ->
        {:ok, relationship.destination}
    end
  end

  defp verify_clear_fields(_module, _path, %{clear_fields: given}) when given in [nil, false],
    do: :ok

  defp verify_clear_fields(module, path, rpc) do
    args = rpc.args || []

    cond do
      :clear_fields in FieldNumbers.names(args) ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: an arg is already named :clear_fields, so the `clear_fields` option cannot be used."
        )

      rpc.clear_fields in for({_name, number} <- args, do: number) ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: `clear_fields` uses number #{rpc.clear_fields}, which an arg already has."
        )

      true ->
        :ok
    end
  end

  defp verify_resource(module, path, rpc) do
    if match?({:module, _}, Code.ensure_compiled(rpc.resource)) and
         Ash.Resource.Info.resource?(rpc.resource) and
         Info.exposed?(rpc.resource) do
      :ok
    else
      FieldNumbers.error(
        module,
        path,
        "#{label(rpc)} uses #{inspect(rpc.resource)}, which is not an Ash resource " <>
          "with a `grpc` block. Add `extensions: [AshGrpc.Resource]` and `grpc do message ...; fields ... end` to it."
      )
    end
  end

  defp default_action_hint(%{action_defaulted?: true} = rpc) do
    names = rpc.resource |> Ash.Resource.Info.actions() |> Enum.map(& &1.name)

    " The action was left out, so it is the one named like the call. Its actions: #{inspect(names)}; name the action as the third argument."
  end

  defp default_action_hint(_rpc), do: ""

  defp verify_action(module, path, rpc) do
    case Ash.Resource.Info.action(rpc.resource, rpc.action) do
      nil ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: #{inspect(rpc.resource)} has no action #{inspect(rpc.action)}." <>
            default_action_hint(rpc)
        )

      %{type: :action} = action ->
        case AshGrpc.Request.result(rpc.resource, action) do
          {:ok, _result} ->
            {:ok, action}

          {:error, reason} ->
            FieldNumbers.error(
              module,
              path,
              "#{label(rpc)}: generic action #{inspect(rpc.action)} returns " <>
                "#{inspect(action.returns)}, which has no protobuf mapping: it #{reason}."
            )
        end

      action ->
        verify_paged(module, path, rpc, action)
    end
  end

  defp verify_paged(module, path, rpc, %{type: :read, pagination: %{} = pagination} = action) do
    reason =
      cond do
        pagination.required? -> "requires pagination"
        pagination.paginate_by_default? -> "paginates by default"
        true -> nil
      end

    if reason && not AshGrpc.Request.paged?(rpc.resource, action, rpc) do
      FieldNumbers.error(
        module,
        path,
        "#{label(rpc)}: read action #{inspect(rpc.action)} #{reason}; " <> unpaged_hint(rpc)
      )
    else
      {:ok, action}
    end
  end

  defp verify_paged(_module, _path, _rpc, action), do: {:ok, action}

  defp unpaged_hint(%{stream?: true}),
    do: "a subscription sends every record, so use a read that does not paginate."

  defp unpaged_hint(_rpc), do: "give the rpc a `page` option."

  defp verify_primary_key(_module, _path, %{args: nil}, _action), do: :ok

  defp verify_primary_key(module, path, rpc, %{type: type}) when type in [:update, :destroy] do
    case Ash.Resource.Info.primary_key(rpc.resource) -- FieldNumbers.names(rpc.args) do
      [] ->
        :ok

      missing ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: the #{type} action needs the primary key in `args`; missing #{inspect(missing)}."
        )
    end
  end

  defp verify_primary_key(_module, _path, _rpc, _action), do: :ok

  defp verify_read_action(module, path, %{read_action: nil} = rpc, %{type: type})
       when type in [:update, :destroy] do
    if Ash.Resource.Info.primary_action(rpc.resource, :read) do
      :ok
    else
      FieldNumbers.error(
        module,
        path,
        "#{label(rpc)}: the #{type} action finds its record with a read action, but " <>
          "#{inspect(rpc.resource)} has no primary read action. Mark one `primary? true` or " <>
          "name one with `read_action:`."
      )
    end
  end

  defp verify_read_action(module, path, %{read_action: name} = rpc, %{type: type})
       when type in [:update, :destroy] do
    case Ash.Resource.Info.action(rpc.resource, name) do
      %{type: :read} ->
        :ok

      _ ->
        FieldNumbers.error(
          module,
          path,
          "#{label(rpc)}: `read_action` #{inspect(name)} is not a read action of #{inspect(rpc.resource)}."
        )
    end
  end

  defp verify_read_action(module, path, %{read_action: name} = rpc, _action)
       when not is_nil(name) do
    FieldNumbers.error(
      module,
      path,
      "#{label(rpc)}: `read_action` only applies to an update or destroy."
    )
  end

  defp verify_read_action(_module, _path, _rpc, _action), do: :ok
end
