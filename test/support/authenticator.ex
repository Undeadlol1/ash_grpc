defmodule AshGrpc.TestSupport.Authenticator do
  @moduledoc false
  @behaviour AshGrpc.Authenticator

  @impl true
  def authenticate(headers) do
    report(headers, {:headers, headers})
    identify(headers)
  end

  defp identify(%{"authorization" => "Bearer keys-down"}), do: {:error, :unavailable}
  defp identify(%{"authorization" => "Bearer retry-later"}), do: {:error, {:unavailable, 3_000}}
  defp identify(%{"authorization" => "Bearer retry-negative"}), do: {:error, {:unavailable, -1}}
  defp identify(%{"authorization" => "Bearer retry-text"}), do: {:error, {:unavailable, "3s"}}

  defp identify(%{"authorization" => "Bearer " <> name} = headers) do
    role = if headers["x-role"] == "admin", do: :admin, else: :member
    {:ok, actor: %{name: name, role: role}, tenant: Map.get(headers, "x-org", "acme")}
  end

  defp identify(_headers), do: {:error, :unauthenticated}

  def report(%{"x-test-pid" => pid}, message),
    do: send(:erlang.list_to_pid(String.to_charlist(pid)), message)

  def report(_headers, _message), do: :ok
end
