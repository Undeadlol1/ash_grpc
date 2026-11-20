defmodule AshGrpc.InferredResponseMapper do
  @moduledoc """
  Default response mapper for unary routes with no explicit `response_mapper:`.
  Passes the Ash result through unchanged (identity mapping); routes needing a
  protobuf reply struct supply their own mapper.
  """

  @spec to_response(term()) :: {:ok, term()}
  def to_response(result), do: {:ok, result}
end
