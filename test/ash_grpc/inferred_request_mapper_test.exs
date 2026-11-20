defmodule AshGrpc.InferredRequestMapperTest do
  use ExUnit.Case, async: true

  defmodule ExampleRequest do
    @moduledoc false
    defstruct [:message, __unknown_fields__: []]
  end

  defmodule NestedItem do
    @moduledoc false
    defstruct [:label, __unknown_fields__: []]
  end

  defmodule ParentRequest do
    @moduledoc false
    defstruct [:name, :item, :items, __unknown_fields__: []]
  end

  describe "GIVEN the inferred request mapper" do
    test "WHEN a request struct is mapped THEN it becomes Ash input and transport metadata fields are dropped" do
      assert {:ok, %{message: "Hello"}} =
               AshGrpc.InferredRequestMapper.to_ash_input(%ExampleRequest{
                 message: "Hello",
                 __unknown_fields__: [1]
               })
    end

    test "WHEN a request has nested messages and repeated fields THEN they become plain maps and lists" do
      request = %ParentRequest{
        name: "parent",
        item: %NestedItem{label: "single", __unknown_fields__: [1]},
        items: [%NestedItem{label: "a"}, %NestedItem{label: "b"}]
      }

      assert {:ok, input} = AshGrpc.InferredRequestMapper.to_ash_input(request)

      assert input.name == "parent"
      assert input.item == %{label: "single"}
      assert input.items == [%{label: "a"}, %{label: "b"}]
      refute Map.has_key?(input.item, :__unknown_fields__)
    end

    test "WHEN a non-map input is given THEN an error mentioning a struct or map is returned" do
      assert {:error, %RuntimeError{message: message}} =
               AshGrpc.InferredRequestMapper.to_ash_input("Hello")

      assert message =~ "struct or map"
    end
  end
end
