{:ok, _} =
  Supervisor.start_link([{Phoenix.PubSub, name: AshGrpc.TestPubSub}], strategy: :one_for_one)

ExUnit.start()
