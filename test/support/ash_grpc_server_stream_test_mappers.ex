defmodule AshGrpc.TestSupport.ServerStreamRequestMapper do
  @moduledoc false

  def to_ash_input(_request), do: {:ok, []}
end

defmodule AshGrpc.TestSupport.ServerStreamResponseMapper do
  @moduledoc false

  def to_response(ticket), do: {:ok, ticket}
end
