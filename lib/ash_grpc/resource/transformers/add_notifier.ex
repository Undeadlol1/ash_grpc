defmodule AshGrpc.Resource.Transformers.AddNotifier do
  @moduledoc false

  use Spark.Dsl.Transformer

  alias Ash.Resource.Info
  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(_transformer), do: false

  def transform(dsl_state) do
    if AshGrpc.Notifier in Info.notifiers(dsl_state) do
      {:ok, dsl_state}
    else
      simple = Info.simple_notifiers(dsl_state)
      {:ok, Transformer.persist(dsl_state, :simple_notifiers, simple ++ [AshGrpc.Notifier])}
    end
  end
end
