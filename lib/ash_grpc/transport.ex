defmodule AshGrpc.Transport do
  @moduledoc """
  The entry points a generated `GRPC.Server` module calls to run a route.

  Each `handle_*` function looks the route up on the domain, builds the Ash
  options from the call (metadata, authenticator, deadline), runs the action
  and returns the mapped reply. `unwrap_response/1` turns the result into the
  reply or a raised `GRPC.RPCError`.
  """

  alias AshGrpc.Domain.Info
  alias AshGrpc.MetadataContext
  alias AshGrpc.Method
  alias AshGrpc.Runner
  alias AshGrpc.ServerStream
  alias AshGrpc.Unary

  def handle_unary(domain, route_name, request, options \\ []) do
    case MetadataContext.merge_action_options(options) do
      {:ok, action_options} ->
        binding =
          Info.unary_binding(domain, route_name, Keyword.put_new(action_options, :runner, Runner))

        case ensure_method_kind(binding, :unary) do
          :ok -> Unary.call(binding, request)
          {:error, error} -> {:error, binding.error_mapper.map(error)}
        end

      {:error, error} ->
        {:error, AshGrpc.ErrorMapper.map(error)}
    end
  end

  def handle_server_stream(domain, route_name, request, materializer, options \\ []) do
    options = Keyword.put_new(options, :grpc_stream, materializer)

    case MetadataContext.merge_action_options(options) do
      {:ok, action_options} ->
        binding =
          Info.binding(domain, route_name, Keyword.put_new(action_options, :runner, Runner))

        case ensure_method_kind(binding, :server_stream) do
          :ok -> ServerStream.call(binding, request, materializer)
          {:error, error} -> stream_error(binding, error, materializer)
        end

      {:error, error} ->
        raise_stream_error(error)
    end
  end

  def handle_client_stream(domain, route_name, request, options \\ []) do
    case MetadataContext.merge_action_options(options) do
      {:ok, action_options} ->
        binding =
          Info.binding(domain, route_name, Keyword.put_new(action_options, :runner, Runner))

        case ensure_method_kind(binding, :client_stream) do
          :ok -> Unary.call(binding, request)
          {:error, error} -> {:error, binding.error_mapper.map(error)}
        end

      {:error, error} ->
        {:error, AshGrpc.ErrorMapper.map(error)}
    end
  end

  def handle_bidirectional_stream(domain, route_name, request, materializer, options \\ []) do
    options = Keyword.put_new(options, :grpc_stream, materializer)

    case MetadataContext.merge_action_options(options) do
      {:ok, action_options} ->
        binding =
          Info.binding(domain, route_name, Keyword.put_new(action_options, :runner, Runner))

        case ensure_method_kind(binding, :bidirectional_stream) do
          :ok -> ServerStream.call(binding, request, materializer)
          {:error, error} -> stream_error(binding, error, materializer)
        end

      {:error, error} ->
        raise_stream_error(error)
    end
  end

  defp ensure_method_kind(%Method{name: _route_name, kind: actual_kind}, expected_kind)
       when actual_kind == expected_kind,
       do: :ok

  defp ensure_method_kind(%Method{name: route_name, kind: actual_kind}, expected_kind) do
    {:error,
     RuntimeError.exception(
       "route #{inspect(route_name)} expects #{inspect(actual_kind)} transport, got #{inspect(expected_kind)}"
     )}
  end

  defp stream_error(binding, error, _materializer) do
    raise error_to_rpc(binding.error_mapper, error)
  end

  defp raise_stream_error(error) do
    raise error_to_rpc(AshGrpc.ErrorMapper, error)
  end

  defp error_to_rpc(error_mapper, error) do
    mapped = error_mapper.map(error)

    case Map.get(mapped, :details) do
      details when is_list(details) and details != [] ->
        GRPC.RPCError.exception(status: mapped.code, message: mapped.message, details: details)

      _ ->
        GRPC.RPCError.exception(status: mapped.code, message: mapped.message)
    end
  end

  @doc """
  Unwraps a handle_* result for a generated server function: returns the
  response on success, raises a mapped `GRPC.RPCError` on failure.
  """
  @spec unwrap_response({:ok, term()} | {:error, term()}) :: term()
  def unwrap_response({:ok, response}), do: response
  def unwrap_response({:error, error}), do: raise(AshGrpc.ErrorMapper.to_rpc_error(error))
end
