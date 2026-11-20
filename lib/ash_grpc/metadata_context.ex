defmodule AshGrpc.MetadataContext do
  @moduledoc false

  alias AshGrpc.Authenticator
  alias AshGrpc.Deadline

  @ash_option_keys [:actor, :authorize?, :tenant, :context, :scope, :tracer, :timeout]
  @internal_option_keys [
    :actor_resolver,
    :authenticator,
    :grpc_stream,
    :metadata,
    :trust_request_metadata
  ]
  @reserved_metadata_prefix "x-ash-"

  def merge_action_options(options) do
    with {:ok, authenticated_actor} <- authenticate(options),
         {:ok, metadata} <- request_metadata(options),
         {:ok, metadata_options} <- to_action_options(metadata, options) do
      explicit_options =
        options
        |> Keyword.drop(@internal_option_keys)
        |> Keyword.take(@ash_option_keys)

      merged =
        metadata_options
        |> Keyword.merge(explicit_options)
        |> apply_deadline(options)

      # A server-derived actor is the trust anchor: it overrides any
      # client-supplied x-ash-actor, but an explicit :actor option (set by
      # in-process callers) still wins.
      {:ok, apply_authenticated_actor(merged, authenticated_actor, options)}
    end
  end

  # grpc-timeout is a standard gRPC header (not an x-ash-* claim), so it is
  # honored regardless of the metadata trust gate. An explicit :timeout
  # option still wins.
  defp apply_deadline(merged, options) do
    if Keyword.has_key?(merged, :timeout) do
      merged
    else
      case Deadline.timeout_option(request_headers(options)) do
        {:timeout, milliseconds} -> Keyword.put(merged, :timeout, milliseconds)
        :none -> merged
      end
    end
  end

  defp authenticate(options) do
    case Authenticator.resolve(options) do
      nil -> {:ok, :no_authenticator}
      module -> Authenticator.authenticate(module, request_headers(options), options)
    end
  end

  # Explicit :metadata (in-process caller) is authoritative; otherwise read
  # the wire headers off the stream. Shared by the authenticator and deadline
  # paths so header resolution lives in one place.
  defp request_headers(options) do
    case Keyword.get(options, :metadata) do
      nil -> stream_headers(Keyword.get(options, :grpc_stream))
      metadata when is_map(metadata) -> metadata
    end
  end

  defp apply_authenticated_actor(merged, :no_authenticator, _options), do: merged

  defp apply_authenticated_actor(merged, authenticated_actor, options) do
    if Keyword.has_key?(options, :actor) do
      merged
    else
      Keyword.put(merged, :actor, authenticated_actor)
    end
  end

  defp request_metadata(options) do
    case Keyword.get(options, :metadata) do
      nil ->
        # Explicit :metadata is caller-controlled and therefore trusted;
        # headers arriving over the wire are not.
        metadata_from_stream(Keyword.get(options, :grpc_stream), options)

      metadata ->
        {:ok, metadata}
    end
  end

  defp stream_headers(%GRPC.Server.Stream{} = stream), do: GRPC.Stream.get_headers(stream)
  defp stream_headers(_stream), do: %{}

  defp metadata_from_stream(%GRPC.Server.Stream{} = stream, options) do
    headers = GRPC.Stream.get_headers(stream)

    cond do
      Keyword.get(options, :trust_request_metadata, false) ->
        {:ok, headers}

      reserved_metadata?(headers) ->
        {:error,
         %{
           code: :permission_denied,
           message:
             "x-ash-* request metadata is not trusted on this endpoint; " <>
               "pass trust_request_metadata: true only behind an authenticated internal gateway"
         }}

      true ->
        {:ok, %{}}
    end
  end

  defp metadata_from_stream(_stream, _options), do: {:ok, %{}}

  defp reserved_metadata?(headers) do
    Enum.any?(headers, fn {key, _value} ->
      is_binary(key) and String.starts_with?(key, @reserved_metadata_prefix)
    end)
  end

  defp to_action_options(metadata, options) when is_map(metadata) do
    with {:ok, authorize?} <- parse_authorize(Map.get(metadata, "x-ash-authorize")),
         {:ok, context} <- parse_context(Map.get(metadata, "x-ash-context")),
         {:ok, actor} <- parse_actor(Map.get(metadata, "x-ash-actor"), options) do
      action_options =
        []
        |> put_present(:tenant, non_empty_string(Map.get(metadata, "x-ash-tenant")))
        |> put_present(:authorize?, authorize?)
        |> put_present(:context, context)
        |> put_present(:actor, actor)

      {:ok, action_options}
    end
  end

  defp parse_authorize(nil), do: {:ok, nil}
  defp parse_authorize("true"), do: {:ok, true}
  defp parse_authorize("false"), do: {:ok, false}

  defp parse_authorize(_value) do
    {:error, invalid_metadata("x-ash-authorize must be true or false")}
  end

  defp parse_context(nil), do: {:ok, nil}

  defp parse_context(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, context} when is_map(context) ->
        {:ok, context}

      _error ->
        {:error, invalid_metadata("x-ash-context must be a JSON object")}
    end
  end

  defp parse_actor(nil, _options), do: {:ok, nil}

  defp parse_actor(value, options) when is_binary(value) do
    with {:ok, actor_payload} <- decode_actor_payload(value),
         {:ok, resolver} <- actor_resolver(options) do
      resolver.resolve(actor_payload)
    end
  end

  defp decode_actor_payload(value) do
    case Jason.decode(value) do
      {:ok, actor_payload} when is_map(actor_payload) ->
        {:ok, actor_payload}

      _error ->
        {:error, invalid_metadata("x-ash-actor must be a JSON object")}
    end
  end

  defp actor_resolver(options) do
    resolver =
      Keyword.get(options, :actor_resolver) ||
        Application.get_env(:ash_grpc, :actor_resolver)

    case resolver do
      module when is_atom(module) ->
        load_actor_resolver(module)

      _other ->
        {:error, invalid_metadata("x-ash-actor requires an ash_grpc actor resolver")}
    end
  end

  defp load_actor_resolver(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        resolver_from_loaded_module(module)

      _result ->
        {:error, invalid_metadata("x-ash-actor requires an ash_grpc actor resolver")}
    end
  end

  defp resolver_from_loaded_module(module) do
    if function_exported?(module, :resolve, 1) do
      {:ok, module}
    else
      {:error, invalid_metadata("x-ash-actor requires an ash_grpc actor resolver")}
    end
  end

  defp non_empty_string(value) when is_binary(value) and value != "", do: value
  defp non_empty_string(_value), do: nil

  defp put_present(options, _key, nil), do: options
  defp put_present(options, key, value), do: Keyword.put(options, key, value)

  defp invalid_metadata(message), do: %{code: :invalid_argument, message: message}
end
