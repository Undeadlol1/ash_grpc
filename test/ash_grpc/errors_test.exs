defmodule AshGrpc.ErrorsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Ash.Error.Changes.Required
  alias Ash.Error.Forbidden.Policy
  alias Ash.Error.Unknown.UnknownError
  alias AshGrpc.Errors
  alias GRPC.Status

  defp violations(%GRPC.RPCError{details: [detail | _]}) do
    Google.Rpc.BadRequest.decode(detail.value).field_violations
  end

  defp error_infos(%GRPC.RPCError{details: [_bad_request | infos]}) do
    for %{type_url: "type.googleapis.com/google.rpc.ErrorInfo", value: value} <- infos,
        do: Google.Rpc.ErrorInfo.decode(value)
  end

  test "forbidden is PERMISSION_DENIED" do
    error = Errors.to_rpc_error(Policy.exception([]))

    assert error.status == Status.permission_denied()
    assert error.message == "Forbidden"
  end

  test "invalid with a field is INVALID_ARGUMENT with a violation naming it" do
    error =
      Errors.to_rpc_error(Required.exception(field: :title, type: :attribute))

    assert error.status == Status.invalid_argument()
    assert [%{field: "title", description: description}] = violations(error)
    assert description == "attribute title is required"
  end

  test "each violation has an ErrorInfo carrying the error code and its field" do
    error = Errors.to_rpc_error(Required.exception(field: :title, type: :attribute))

    assert [%{reason: "required", domain: "ash", metadata: %{"field" => "title"}}] =
             error_infos(error)
  end

  test "an error without a field has an ErrorInfo with its code and an empty field" do
    error = Errors.to_rpc_error(Ash.Error.Changes.InvalidChanges.exception(message: "no good"))

    assert [%{reason: "invalid_changes", metadata: %{"field" => ""}}] = error_infos(error)
  end

  test "invalid without a field still carries its message" do
    error = Errors.to_rpc_error(Ash.Error.Changes.InvalidChanges.exception(message: "no good"))

    assert error.status == Status.invalid_argument()
    assert [%{field: "", description: description}] = violations(error)
    assert description == "no good"
  end

  test "an invalid error wrapping a non-invalid error never sends its text" do
    log =
      capture_log(fn ->
        error =
          Errors.to_rpc_error([
            Ash.Error.Changes.InvalidAttribute.exception(field: :title, message: "is bad"),
            UnknownError.exception(error: "ERROR 42P01 relation secret_table does not exist")
          ])

        assert error.status == Status.internal()
        assert error.message == "Internal error"
        assert error.details == nil or error.details == []
      end)

    assert log =~ "secret_table"
  end

  test "not found is NOT_FOUND" do
    error =
      Errors.to_rpc_error(Ash.Error.Query.NotFound.exception(resource: AshGrpc.TestSupport.Post))

    assert error.status == Status.not_found()
  end

  test "an Ash timeout is DEADLINE_EXCEEDED" do
    error = Errors.to_rpc_error(Ash.Error.Invalid.Timeout.exception(timeout: 10))

    assert error.status == Status.deadline_exceeded()
  end

  test "an unknown error is INTERNAL with a fixed message and a logged cause" do
    log =
      capture_log(fn ->
        error = Errors.to_rpc_error(UnknownError.exception(error: "secret"))

        assert error.status == Status.internal()
        assert error.message == "Internal error"
      end)

    assert log =~ "secret"
  end

  test "a framework error is INTERNAL with a fixed message" do
    capture_log(fn ->
      error =
        Errors.to_rpc_error(Ash.Error.Framework.AssumptionFailed.exception(message: "secret"))

      assert error.status == Status.internal()
      assert error.message == "Internal error"
    end)
  end

  test "an error list mixing forbidden and invalid is one status that hides no data" do
    capture_log(fn ->
      error =
        Errors.to_rpc_error([
          Policy.exception([]),
          Required.exception(field: :title, type: :attribute)
        ])

      assert error.status in [Status.permission_denied(), Status.invalid_argument()]
      assert error.message in ["Forbidden", "Invalid request"]
    end)
  end

  test "authenticator refusals map to UNAUTHENTICATED and UNAVAILABLE" do
    assert Errors.to_rpc_error(:unauthenticated).status == Status.unauthenticated()
    assert Errors.to_rpc_error(:unavailable).status == Status.unavailable()
  end
end
