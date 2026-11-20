defmodule AshGrpc.Notifier do
  @moduledoc """
  Tells the subscriptions watching a resource that one of its records was
  created, updated or destroyed. `AshGrpc.Resource` adds it to the resource, so
  there is nothing to set up; a resource that lists it too is notified once.

  `notify/1` runs in the writer's process after the write, so it only sends
  `{AshGrpc.Notifier, resource, action_type, primary_key, tenant}` to each
  member of the `:pg` group of the resource, in the `:pg` scope
  `AshGrpc.Notifier` that the `:ash_grpc` application starts. No record data
  is sent: each subscription reads the record again as its own actor. Members
  on connected nodes get the message too. See the
  [Subscriptions](subscriptions.md) guide.
  """

  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{resource: resource, action: %{type: type}} = notification) do
    key = Map.take(notification.data, Ash.Resource.Info.primary_key(resource))
    message = {__MODULE__, resource, type, key, tenant(notification.changeset)}

    for pid <- :pg.get_members(__MODULE__, resource), do: send(pid, message)
    :ok
  end

  @doc false
  def subscribe(resource), do: :pg.join(__MODULE__, resource, self())

  defp tenant(%{to_tenant: tenant}), do: tenant
  defp tenant(_changeset), do: nil
end
