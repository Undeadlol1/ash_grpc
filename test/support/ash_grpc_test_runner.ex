defmodule AshGrpc.TestRunner do
  @moduledoc false

  def run(
        %AshGrpc.Method{resource: resource, action: action, action_options: action_options},
        input
      ) do
    case Ash.Resource.Info.action(resource, action).type do
      :create ->
        resource
        |> Ash.Changeset.for_create(action, input, action_options)
        |> Ash.create(Keyword.put_new(action_options, :authorize?, false))

      :update ->
        input
        |> Ash.Changeset.for_update(action, %{}, action_options)
        |> Ash.update(Keyword.put_new(action_options, :authorize?, false))

      type ->
        {:error,
         RuntimeError.exception("unsupported ash_grpc test action type: #{inspect(type)}")}
    end
  end
end
