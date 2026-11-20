defmodule AshGrpc.HandlerTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Handler

  test "ash_opts forwards actor, tenant and context and always authorizes" do
    auth_opts = [actor: :someone, tenant: "acme", context: %{shared: 1}, ignored: true]

    assert {opts, []} = Handler.ash_opts(auth_opts, %GRPC.Server.Stream{})
    assert opts[:actor] == :someone
    assert opts[:tenant] == "acme"
    assert opts[:context] == %{shared: 1}
    assert opts[:authorize?] == true
    refute Keyword.has_key?(opts, :ignored)
  end
end
