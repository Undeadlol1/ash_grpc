defmodule AshGrpc.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [%{id: AshGrpc.Notifier, start: {:pg, :start_link, [AshGrpc.Notifier]}}]
    Supervisor.start_link(children, strategy: :one_for_one, name: AshGrpc.Supervisor)
  end
end
