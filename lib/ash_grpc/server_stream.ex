defmodule AshGrpc.ServerStream do
  @moduledoc """
  Runs a server-streaming (or bidirectional) route: executes the bound Ash
  action, then maps and sends each result via `GRPC.Server.send_reply`,
  halting with `deadline_exceeded` once the client's propagated deadline
  passes. Also used by bidirectional routes (stream-in, stream-out).
  """

  alias AshGrpc.Method

  @spec call(Method.t(), term(), term()) :: :ok
  def call(%Method{} = binding, request, materializer) do
    case execute(binding, request) do
      {:ok, responses} ->
        deadline = deadline_from(binding)

        responses
        |> to_enumerable()
        |> Enum.each(fn item ->
          ensure_within_deadline!(deadline)
          send_response(materializer, binding, item)
        end)

        :ok

      {:error, error} ->
        raise to_rpc_error(error, binding)
    end
  end

  # The client's grpc-timeout is propagated as an Ash :timeout; reuse it to
  # stop pushing replies once the deadline has passed instead of streaming
  # to a client that has already given up.
  @doc false
  @spec deadline_from(Method.t(), integer()) :: integer() | :infinity
  def deadline_from(
        %Method{action_options: action_options},
        now \\ System.monotonic_time(:millisecond)
      ) do
    case Keyword.get(action_options || [], :timeout) do
      milliseconds when is_integer(milliseconds) and milliseconds > 0 -> now + milliseconds
      _ -> :infinity
    end
  end

  @doc false
  @spec exceeded?(integer() | :infinity, integer()) :: boolean()
  def exceeded?(:infinity, _now), do: false
  def exceeded?(deadline, now), do: now >= deadline

  defp ensure_within_deadline!(deadline) do
    if exceeded?(deadline, System.monotonic_time(:millisecond)) do
      raise GRPC.RPCError.exception(
              status: :deadline_exceeded,
              message: "stream deadline exceeded before all replies were sent"
            )
    end

    :ok
  end

  defp execute(%Method{} = binding, request) do
    with {:ok, ash_input} <- binding.request_mapper.to_ash_input(request) do
      run_action(binding, ash_input)
    end
  end

  defp run_action(%Method{runner: runner} = binding, ash_input) do
    runner.run(binding, ash_input)
  end

  defp send_response(_materializer, %Method{} = binding, {:error, error}),
    do: raise(to_rpc_error(error, binding))

  defp send_response(materializer, %Method{} = binding, item) do
    case binding.response_mapper.to_response(item) do
      {:ok, response} ->
        GRPC.Server.send_reply(materializer, response)

      {:error, error} ->
        raise to_rpc_error(error, binding)
    end
  end

  defp to_enumerable(%Elixir.Stream{} = stream), do: stream
  defp to_enumerable(stream) when is_function(stream, 2), do: stream
  defp to_enumerable(list) when is_list(list), do: list
  defp to_enumerable(item), do: [item]

  defp to_rpc_error(error, %Method{} = binding) do
    mapped_error = binding.error_mapper.map(error)

    case Map.get(mapped_error, :details) do
      details when is_list(details) and details != [] ->
        GRPC.RPCError.exception(
          status: mapped_error.code,
          message: mapped_error.message,
          details: details
        )

      _ ->
        GRPC.RPCError.exception(status: mapped_error.code, message: mapped_error.message)
    end
  end
end
