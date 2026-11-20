defmodule AshGrpc.InferredResponseMapperTest do
  use ExUnit.Case, async: true

  describe "GIVEN the inferred response mapper" do
    test "WHEN an Ash result is mapped THEN it is returned unchanged" do
      result = %{message: "Hello"}

      assert {:ok, ^result} = AshGrpc.InferredResponseMapper.to_response(result)
    end
  end
end
