defmodule AshGrpc.Errors do
  @moduledoc """
  Maps failures to gRPC statuses.

  Invalid input is `INVALID_ARGUMENT` with a `google.rpc.BadRequest` detail
  listing a `FieldViolation` per field, then one `google.rpc.ErrorInfo` per
  violation whose `reason` is the error module's last name segment in snake_case
  (`required`, `invalid_attribute`)
  and whose `metadata["field"]` is the same field path; forbidden is `PERMISSION_DENIED`; a
  missing record is `NOT_FOUND`; an Ash timeout is `DEADLINE_EXCEEDED`.
  Anything else is `INTERNAL` with a fixed message: the cause is logged on the
  server, never sent.
  """

  alias AshGrpc.Status
  alias Google.Rpc.BadRequest
  alias Google.Rpc.ErrorInfo
  alias GRPC.RPCError

  require Logger

  @doc "The `GRPC.RPCError` for an authenticator refusal, an expired subscription or an Ash error."
  @spec to_rpc_error(term()) :: Exception.t()
  def to_rpc_error(:unauthenticated), do: rpc_error(:unauthenticated, "Unauthenticated")
  def to_rpc_error(:unavailable), do: rpc_error(:unavailable, "Unavailable")
  def to_rpc_error(:deadline_exceeded), do: rpc_error(:deadline_exceeded, "Deadline exceeded")

  def to_rpc_error({:too_many_failures, limit}),
    do: rpc_error(:resource_exhausted, "More than #{limit} messages failed")

  def to_rpc_error({:too_many_subscriptions, limit}),
    do: rpc_error(:resource_exhausted, "More than #{limit} subscriptions are open")

  def to_rpc_error(error) do
    case Ash.Error.to_error_class(error) do
      %Ash.Error.Forbidden{} ->
        rpc_error(:permission_denied, "Forbidden")

      %Ash.Error.Invalid{errors: errors} = invalid ->
        invalid(errors, invalid)

      other ->
        internal(other)
    end
  end

  @doc """
  The `google.rpc.Status` of an error from `to_rpc_error/1`: what a streaming rpc
  reports for one message that failed. It carries the status code, message and
  details the unary call raises, taken from that same error.
  """
  @spec to_status(Exception.t()) :: %Status{}
  def to_status(%RPCError{status: code, message: message, details: details}),
    do: %Status{code: code, message: message, details: details || []}

  @doc "An `INTERNAL` error; logs the cause."
  @spec internal(term(), Exception.stacktrace()) :: Exception.t()
  def internal(error, stacktrace \\ []) do
    Logger.error("AshGrpc request failed: " <> Exception.format(:error, error, stacktrace))
    rpc_error(:internal, "Internal error")
  end

  defp invalid(errors, whole) do
    cond do
      Enum.any?(errors, &is_struct(&1, Ash.Error.Query.NotFound)) ->
        rpc_error(:not_found, "Not found")

      Enum.any?(errors, &is_struct(&1, Ash.Error.Invalid.Timeout)) ->
        rpc_error(:deadline_exceeded, "Deadline exceeded")

      Enum.any?(errors, &(&1.class != :invalid)) ->
        internal(whole)

      true ->
        found =
          for error <- errors,
              field <- fields(error),
              do: {error, field_path(path(error) ++ [field])}

        violations =
          for {error, field} <- found,
              do: %BadRequest.FieldViolation{
                field: field,
                description: Exception.message(%{error | bread_crumbs: []})
              }

        bad_request = %Google.Protobuf.Any{
          type_url: "type.googleapis.com/google.rpc.BadRequest",
          value: BadRequest.encode(%BadRequest{field_violations: violations})
        }

        error_infos =
          for {error, field} <- found,
              do: %Google.Protobuf.Any{
                type_url: "type.googleapis.com/google.rpc.ErrorInfo",
                value:
                  ErrorInfo.encode(%ErrorInfo{
                    reason: code(error),
                    domain: "ash",
                    metadata: %{"field" => field}
                  })
              }

        RPCError.exception(
          status: :invalid_argument,
          message: "Invalid request",
          details: [bad_request | error_infos]
        )
    end
  end

  defp code(%module{}), do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp fields(error) do
    case Map.get(error, :fields) do
      fields when is_list(fields) and fields != [] -> fields
      _ -> [Map.get(error, :field) || ""]
    end
  end

  defp path(error) do
    case Map.get(error, :path) do
      [first | _] = path when is_atom(first) -> path
      _ -> []
    end
  end

  defp field_path(segments) do
    Enum.reduce(segments, "", fn
      index, path when is_integer(index) -> "#{path}[#{index}]"
      segment, "" -> to_string(segment)
      segment, path -> "#{path}.#{segment}"
    end)
  end

  defp rpc_error(status, message), do: RPCError.exception(status: status, message: message)
end
