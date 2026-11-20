defmodule AshGrpc.UnaryTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Domain.Info
  alias AshGrpc.TestRunner
  alias AshGrpc.TestSupport.UnaryDirectGreeting
  alias AshGrpc.TestSupport.UnaryDirectGreetingRequest
  alias AshGrpc.TestSupport.UnaryFailingRequestMapper
  alias AshGrpc.TestSupport.UnaryFailingResponseMapper
  alias AshGrpc.TestSupport.UnaryGreeting
  alias AshGrpc.TestSupport.UnaryGreetingDesk
  alias AshGrpc.TestSupport.UnaryGreetingRequest
  alias AshGrpc.TestSupport.UnaryGreetingRequestMapper
  alias AshGrpc.TestSupport.UnaryGreetingResponse
  alias AshGrpc.TestSupport.UnaryGreetingResponseMapper
  alias AshGrpc.TestSupport.UnaryPositionalGreeting
  alias AshGrpc.TestSupport.UnaryPositionalGreetingDesk
  alias AshGrpc.TestSupport.UnaryPositionalGreetingRequest

  describe "GIVEN the unary gRPC route" do
    test "WHEN a unary request is sent THEN the reply is the mapped protobuf message" do
      binding =
        AshGrpc.Method.bind(
          resource: UnaryGreeting,
          action: :create,
          request_mapper: UnaryGreetingRequestMapper,
          response_mapper: UnaryGreetingResponseMapper,
          runner: TestRunner
        )

      assert {:ok, %UnaryGreetingResponse{message: "Hello, Ada"}} =
               AshGrpc.Unary.call(binding, %UnaryGreetingRequest{name: "Ada"})
    end

    test "WHEN a unary route omits its mapper modules THEN the binding uses inferred request and response mappers" do
      assert %AshGrpc.Method{
               request_mapper: AshGrpc.InferredRequestMapper,
               response_mapper: AshGrpc.InferredResponseMapper,
               runner: TestRunner
             } = Info.unary_binding(UnaryGreetingDesk, :create_greeting, runner: TestRunner)
    end

    test "WHEN the request already matches the action contract THEN the route runs without explicit mappers" do
      assert {:ok, %UnaryDirectGreeting{message: "Hello, Ada"}} =
               AshGrpc.Transport.handle_unary(
                 UnaryGreetingDesk,
                 :create_greeting,
                 %UnaryDirectGreetingRequest{message: "Hello, Ada"}
               )
    end

    test "WHEN the code interface expects positional args THEN the route runs without explicit mappers" do
      assert {:ok, %UnaryPositionalGreeting{subject: "Hello", body: "Ada"}} =
               AshGrpc.Transport.handle_unary(
                 UnaryPositionalGreetingDesk,
                 :submit_greeting,
                 %UnaryPositionalGreetingRequest{
                   subject: "Hello",
                   body: "Ada",
                   __unknown_fields__: [1]
                 }
               )
    end

    test "WHEN a binding leaves out the runner THEN building it raises naming the missing option" do
      assert_raise ArgumentError, ~r/missing required ash_grpc binding options: runner/, fn ->
        AshGrpc.Method.bind(
          resource: UnaryGreeting,
          action: :create,
          request_mapper: UnaryGreetingRequestMapper,
          response_mapper: UnaryGreetingResponseMapper
        )
      end
    end

    test "WHEN the request mapper fails THEN the call returns an invalid argument error naming the field" do
      binding =
        AshGrpc.Method.bind(
          resource: UnaryGreeting,
          action: :create,
          request_mapper: UnaryFailingRequestMapper,
          response_mapper: UnaryGreetingResponseMapper,
          runner: TestRunner
        )

      assert {:error, %{code: :invalid_argument, message: message}} =
               AshGrpc.Unary.call(binding, %UnaryGreetingRequest{name: "Ada"})

      assert message =~ "name"
    end

    test "WHEN the response mapper fails THEN the call returns an internal error" do
      binding =
        AshGrpc.Method.bind(
          resource: UnaryGreeting,
          action: :create,
          request_mapper: UnaryGreetingRequestMapper,
          response_mapper: UnaryFailingResponseMapper,
          runner: TestRunner
        )

      assert {:error, %{code: :internal, message: message}} =
               AshGrpc.Unary.call(binding, %UnaryGreetingRequest{name: "Ada"})

      assert message =~ "response mapper exploded"
    end

    test "WHEN Ash rejects the input as invalid THEN the call returns an invalid argument error naming the field" do
      binding =
        AshGrpc.Method.bind(
          resource: UnaryGreeting,
          action: :create,
          request_mapper: UnaryGreetingRequestMapper,
          response_mapper: UnaryGreetingResponseMapper,
          runner: TestRunner
        )

      assert {:error, %{code: :invalid_argument, message: message}} =
               AshGrpc.Unary.call(binding, %UnaryGreetingRequest{name: nil})

      assert message =~ "message"
    end
  end
end
