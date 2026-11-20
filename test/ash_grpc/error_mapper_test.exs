defmodule AshGrpc.ErrorMapperTest do
  use ExUnit.Case, async: true

  alias Ash.Error.Changes.InvalidAttribute
  alias AshGrpc.Examples.SupportTicket
  alias Google.Protobuf.Any
  alias Google.Rpc.BadRequest

  describe "GIVEN the ash error mapper" do
    test "WHEN a forbidden error is mapped THEN it becomes a permission denied shape" do
      error = Ash.Error.Forbidden.Policy.exception([])

      assert %{code: :permission_denied, message: message} = AshGrpc.ErrorMapper.map(error)
      assert message =~ "forbidden"
    end

    test "WHEN a not found error is mapped THEN it becomes a not found shape that names the missing id" do
      error =
        Ash.Error.Query.NotFound.exception(primary_key: "missing-id", resource: SupportTicket)

      assert %{code: :not_found, message: message} = AshGrpc.ErrorMapper.map(error)
      assert message =~ "missing-id"
    end

    test "WHEN a framework error is mapped THEN it becomes a failed precondition shape with its message" do
      error = Ash.Error.Framework.AssumptionFailed.exception(message: "route metadata missing")

      assert %{code: :failed_precondition, message: message} = AshGrpc.ErrorMapper.map(error)
      assert message =~ "route metadata missing"
    end

    test "WHEN a wrapped unknown error is mapped THEN it becomes an internal shape that keeps the message" do
      assert %{code: :internal, message: message} =
               AshGrpc.ErrorMapper.map({:error, RuntimeError.exception("boom")})

      assert message =~ "boom"
    end

    test "WHEN an already mapped error shape is mapped again THEN it is kept unchanged" do
      assert %{code: :invalid_argument, message: "subject and body are required"} =
               AshGrpc.ErrorMapper.map(%{
                 code: :invalid_argument,
                 message: "subject and body are required",
                 details: %{field: :subject}
               })
    end

    test "WHEN a validation error on two fields is mapped THEN each field becomes a bad request violation in details" do
      invalid =
        Ash.Error.to_error_class([
          InvalidAttribute.exception(field: :subject, message: "is required"),
          InvalidAttribute.exception(field: :body, message: "is too short")
        ])

      assert %{code: :invalid_argument, details: [%Any{} = any]} =
               AshGrpc.ErrorMapper.map(invalid)

      assert %BadRequest{field_violations: violations} =
               BadRequest.decode(any.value)

      fields = violations |> Enum.map(& &1.field) |> Enum.sort()
      assert fields == ["body", "subject"]

      subject_violation = Enum.find(violations, &(&1.field == "subject"))
      assert subject_violation.description =~ "required"
    end

    test "WHEN an error without field diagnostics is mapped THEN no details are included" do
      invalid =
        Ash.Error.to_error_class([Ash.Error.Unknown.UnknownError.exception(error: "boom")])

      refute Map.has_key?(AshGrpc.ErrorMapper.map(invalid), :details)
    end
  end

  describe "GIVEN the ash error mapper WHEN an ash error is mapped to an rpc error" do
    test "THEN a gRPC error is built without a nil details field" do
      error = AshGrpc.ErrorMapper.to_rpc_error(%{code: :not_found, message: "gone"})

      assert %GRPC.RPCError{message: "gone", details: nil} = error
      assert error.status == GRPC.Status.not_found()
    end

    test "THEN field-violation details are attached when the Ash error carries them" do
      invalid =
        Ash.Error.to_error_class([
          InvalidAttribute.exception(field: :subject, message: "required")
        ])

      error = AshGrpc.ErrorMapper.to_rpc_error(invalid)

      assert error.status == GRPC.Status.invalid_argument()
      assert [%Any{}] = error.details
    end
  end
end
