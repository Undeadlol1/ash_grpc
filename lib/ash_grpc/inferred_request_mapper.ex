defmodule AshGrpc.InferredRequestMapper do
  @moduledoc """
  Default request mapper for unary routes with no explicit `request_mapper:`.

  Turns a protobuf request into the arguments of the domain code interface
  when the route has one, or into a map of the action's accepted inputs.
  """

  alias Ash.Resource.Info
  alias AshGrpc.Method

  @spec to_ash_input(struct() | map()) :: {:ok, map()} | {:error, term()}
  @spec to_ash_input(Method.t(), struct() | map()) :: {:ok, map() | list()} | {:error, term()}
  def to_ash_input(%Method{} = binding, request) do
    with {:ok, request_map} <- request_to_map(request) do
      {:ok, infer_binding_input(binding, request_map)}
    end
  end

  def to_ash_input(%_{} = request) do
    request_to_map(request)
  end

  def to_ash_input(request) when is_map(request) do
    request_to_map(request)
  end

  def to_ash_input(request) do
    {:error,
     RuntimeError.exception(
       "ash_grpc inferred request mapping only supports struct or map inputs, got: #{inspect(request)}"
     )}
  end

  defp request_to_map(%_{} = request) do
    request
    |> Map.from_struct()
    |> request_to_map()
  end

  defp request_to_map(request) when is_map(request) do
    {:ok,
     request
     |> Enum.reject(fn {key, _value} -> internal_field?(key) end)
     |> Map.new(fn {key, value} -> {key, normalize_value(value)} end)}
  end

  # Nested protobuf messages and repeated fields arrive as structs / lists of
  # structs; Ash can only cast plain maps and lists.
  defp normalize_value(%_{} = struct) do
    {:ok, map} = request_to_map(Map.from_struct(struct))
    map
  end

  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp infer_binding_input(binding, request_map) do
    case interface_args(binding) do
      [_ | _] = args ->
        Enum.map(args, &request_value(request_map, &1))

      [] ->
        filter_action_inputs(binding, request_map)

      nil ->
        request_map
    end
  end

  defp interface_args(%Method{domain: domain, handler: handler, resource: resource, name: name}) do
    domain_module =
      cond do
        spark_domain?(domain) -> domain
        spark_domain?(handler) -> handler
        true -> nil
      end

    with domain_module when not is_nil(domain_module) <- domain_module,
         %{entities: resources} <- domain_module.spark_dsl_config()[[:resources]],
         resource_reference when not is_nil(resource_reference) <-
           Enum.find(resources, &(&1.resource == resource)),
         definitions when is_list(definitions) <- Map.get(resource_reference, :definitions),
         %{args: args} <- Enum.find(definitions, &(&1.name == name)) do
      args
    else
      _ -> nil
    end
  end

  defp filter_action_inputs(%Method{resource: resource, action: action_name}, request_map) do
    action = Info.action(resource, action_name)

    allowed_keys =
      Enum.uniq(action.accept ++ Enum.map(action.arguments || [], & &1.name))

    if allowed_keys == [] do
      request_map
    else
      allowed_keys
      |> Map.new(fn key -> {key, request_value(request_map, key)} end)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end
  end

  defp request_value(request_map, key) do
    Map.get(request_map, key) || Map.get(request_map, Atom.to_string(key))
  end

  defp spark_domain?(module) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :spark_dsl_config, 0)

  defp spark_domain?(_module), do: false

  defp internal_field?(key) when is_atom(key) do
    key
    |> Atom.to_string()
    |> String.starts_with?("__")
  end

  defp internal_field?(_key), do: false
end
