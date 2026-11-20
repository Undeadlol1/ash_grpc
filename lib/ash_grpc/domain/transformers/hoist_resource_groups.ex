defmodule AshGrpc.Domain.Transformers.HoistResourceGroups do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias AshGrpc.Domain.ResourceGroup
  alias AshGrpc.Domain.Rpc
  alias AshGrpc.Domain.Service
  alias Spark.Dsl.Transformer

  def transform(dsl_state) do
    dsl_state
    |> Transformer.get_entities([:grpc])
    |> Enum.filter(&match?(%Service{}, &1))
    |> Enum.reduce_while({:ok, dsl_state}, fn service, {:ok, dsl} ->
      case hoist(service) do
        {:ok, flat} ->
          {:cont,
           {:ok, Transformer.replace_entity(dsl, [:grpc], flat, &(&1.name == service.name))}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp hoist(service) do
    with {:ok, rpcs} <- flatten(service.rpcs),
         {:ok, subscriptions} <- flatten(service.subscriptions ++ grouped_subscriptions(service)) do
      {:ok, %{service | rpcs: rpcs, subscriptions: subscriptions}}
    end
  end

  defp grouped_subscriptions(service) do
    for %ResourceGroup{} = group <- service.rpcs,
        subscription <- group.subscriptions,
        do: %{subscription | resource: group.resource}
  end

  defp flatten(entities) do
    entities
    |> Enum.flat_map(fn
      %ResourceGroup{} = group -> Enum.map(group.rpcs, &%{&1 | resource: group.resource})
      call -> [call]
    end)
    |> Enum.reduce_while({:ok, []}, fn call, {:ok, acc} ->
      case Rpc.default_action(call) do
        {:ok, call} -> {:cont, {:ok, [call | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> then(fn
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      error -> error
    end)
  end
end
