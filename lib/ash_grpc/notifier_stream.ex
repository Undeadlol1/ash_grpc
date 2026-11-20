defmodule AshGrpc.NotifierStream do
  @moduledoc """
  Builds a lazy stream from a notifier-backed event source.
  """

  @type limit :: pos_integer() | :infinity

  defmodule Source do
    @moduledoc """
    Behaviour for an event source that feeds `AshGrpc.NotifierStream.stream/2`.
    """

    @callback subscribe(keyword()) :: {:ok, term()} | {:error, term()}
    @callback handle_message(term(), term()) ::
                {:emit, term(), term()} | {:skip, term()} | {:stop, term()}
    @callback unsubscribe(term()) :: :ok
  end

  @spec stream(module(), keyword()) :: Enumerable.t()
  def stream(source, options) when is_atom(source) and is_list(options) do
    Stream.resource(
      fn -> init_source(source, options) end,
      &next_item/1,
      &cleanup/1
    )
  end

  defp init_source(source, options) do
    case source.subscribe(options) do
      {:ok, source_state} ->
        %{
          source: source,
          source_state: source_state,
          remaining: remaining_limit(options),
          timeout: idle_timeout(options)
        }

      {:error, error} ->
        raise ArgumentError, "failed to subscribe notifier stream source: #{inspect(error)}"
    end
  end

  # Long-lived subscriptions (e.g. live updates) must pass `timeout: :infinity`
  # or they silently halt after the idle window; the default only suits
  # bounded request/response style streams.
  defp idle_timeout(options) do
    case Keyword.get(options, :timeout, 5_000) do
      :infinity ->
        :infinity

      timeout when is_integer(timeout) and timeout > 0 ->
        timeout

      other ->
        raise ArgumentError,
              "notifier stream :timeout must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp next_item(%{remaining: 0} = state), do: {:halt, state}

  defp next_item(state) do
    receive do
      message ->
        handle_message_result(state.source.handle_message(message, state.source_state), state)
    after
      state.timeout ->
        {:halt, state}
    end
  end

  defp handle_message_result({:emit, item, source_state}, state) do
    {[item], %{state | source_state: source_state, remaining: decrement_limit(state.remaining)}}
  end

  defp handle_message_result({:skip, source_state}, state) do
    next_item(%{state | source_state: source_state})
  end

  defp handle_message_result({:stop, source_state}, state) do
    {:halt, %{state | source_state: source_state}}
  end

  defp cleanup(%{source: source, source_state: source_state}) do
    source.unsubscribe(source_state)
  end

  defp remaining_limit(options) do
    case Keyword.get(options, :limit, :infinity) do
      limit when is_integer(limit) and limit > 0 -> limit
      _ -> :infinity
    end
  end

  defp decrement_limit(:infinity), do: :infinity
  defp decrement_limit(limit), do: limit - 1
end
