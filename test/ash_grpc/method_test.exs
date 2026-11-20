defmodule AshGrpc.MethodTest do
  use ExUnit.Case, async: true

  alias AshGrpc.TestRunner
  alias AshGrpc.TestSupport.UnaryGreetingRequestMapper
  alias AshGrpc.TestSupport.UnaryGreetingResponseMapper

  describe "GIVEN the method binding" do
    test "WHEN a binding is built with explicit modules THEN those modules are kept and the default error mapper is used" do
      binding =
        AshGrpc.Method.bind(
          resource: __MODULE__,
          action: :create,
          request_mapper: UnaryGreetingRequestMapper,
          response_mapper: UnaryGreetingResponseMapper,
          runner: TestRunner
        )

      assert binding.resource == __MODULE__
      assert binding.action == :create
      assert binding.request_mapper == UnaryGreetingRequestMapper
      assert binding.response_mapper == UnaryGreetingResponseMapper
      assert binding.runner == TestRunner
      assert binding.error_mapper == AshGrpc.ErrorMapper
    end

    test "WHEN a binding is built without a runner THEN an argument error names the missing runner option" do
      assert_raise ArgumentError, ~r/missing required ash_grpc binding options: runner/, fn ->
        AshGrpc.Method.bind(
          resource: __MODULE__,
          action: :create,
          request_mapper: UnaryGreetingRequestMapper,
          response_mapper: UnaryGreetingResponseMapper
        )
      end
    end
  end
end
