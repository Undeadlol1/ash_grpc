defmodule AshGrpc.Unary do
  @moduledoc """
  Executes one unary gRPC request through an Ash action.
  """

  alias AshGrpc.Method

  @spec call(Method.t(), term()) :: {:ok, term()} | {:error, map()}
  def call(%Method{} = binding, request) do
    with {:ok, ash_input} <- map_request(binding, request),
         {:ok, result} <- run_action(binding, ash_input),
         {:ok, response} <- map_response(binding, result) do
      {:ok, response}
    else
      {:error, error} -> {:error, binding.error_mapper.map(error)}
    end
  end

  defp map_request(%Method{request_mapper: mapper} = binding, request) do
    if exported?(mapper, :to_ash_input, 2) do
      mapper.to_ash_input(binding, request)
    else
      mapper.to_ash_input(request)
    end
  end

  defp map_response(%Method{response_mapper: mapper} = binding, result) do
    if exported?(mapper, :to_response, 2) do
      mapper.to_response(binding, result)
    else
      mapper.to_response(result)
    end
  end

  defp exported?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp run_action(%Method{runner: runner} = binding, ash_input) do
    runner.run(binding, ash_input)
  end
end
