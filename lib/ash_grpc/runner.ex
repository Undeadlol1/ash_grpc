defmodule AshGrpc.Runner do
  @moduledoc """
  Default execution strategy for a bound route: invokes the domain code
  interface function (or a route `handler:` override) with the mapped Ash
  input, passing merged action options when the handler accepts them.
  """

  alias AshGrpc.Method

  def run(%Method{handler: handler, name: name, action_options: action_options}, ash_input)
      when not is_nil(handler) and not is_nil(name) and is_atom(handler) and is_atom(name) do
    args = List.wrap(ash_input)

    if action_options != [] and exported?(handler, name, length(args) + 1) do
      apply(handler, name, args ++ [action_options])
    else
      apply(handler, name, args)
    end
  end

  def run(%Method{}, _ash_input) do
    {:error, RuntimeError.exception("ash_grpc runner requires domain-bound method metadata")}
  end

  defp exported?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
