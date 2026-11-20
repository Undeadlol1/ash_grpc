defmodule AshGrpc.ErrorMapper do
  @moduledoc """
  Maps Ash errors into gRPC error shape: a status `code`, a human `message`,
  and — for validation failures — structured `details` following the
  `google.rpc` error model.

  Ash's `Invalid` errors carry per-field diagnostics (`:field`/`:fields`
  and a message). Those are translated into a
  `google.rpc.BadRequest.FieldViolation` list, packed into a
  `google.protobuf.Any`, and surfaced on the `grpc-status-details-bin`
  trailer so clients can render field-level errors instead of parsing a
  flat string. This is the gRPC counterpart to AshJsonApi's per-field
  JSON:API error objects.
  """

  alias Ash.Error.Invalid
  alias Google.Rpc.BadRequest
  alias Google.Rpc.BadRequest.FieldViolation

  @type mapped :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          optional(:details) => [Google.Protobuf.Any.t()]
        }

  @doc """
  Builds a `GRPC.RPCError` from any error, attaching structured details
  only when present. `GRPC.RPCError` rejects a nil `:details`, so callers
  must never pass one through by hand — use this helper.
  """
  @spec to_rpc_error(term()) :: Exception.t()
  def to_rpc_error(error) do
    mapped = map(error)

    args =
      case Map.get(mapped, :details) do
        details when is_list(details) and details != [] ->
          [status: mapped.code, message: mapped.message, details: details]

        _ ->
          [status: mapped.code, message: mapped.message]
      end

    GRPC.RPCError.exception(args)
  end

  @spec map(term()) :: mapped
  def map({:error, error}), do: map(error)

  def map(%{code: code, message: message} = error) when is_atom(code) and is_binary(message) do
    Map.take(error, [:code, :message, :details])
  end

  def map(%Ash.Error.Query.NotFound{} = error) do
    %{code: :not_found, message: Exception.message(error)}
  end

  def map(error) do
    error
    |> Ash.Error.to_error_class()
    |> to_grpc_error()
  end

  defp to_grpc_error(%Invalid{errors: errors} = error) do
    base = %{code: :invalid_argument, message: Exception.message(error)}

    case field_violations(errors) do
      [] -> base
      violations -> Map.put(base, :details, [pack_bad_request(violations)])
    end
  end

  defp to_grpc_error(%Ash.Error.Forbidden{} = error) do
    %{code: :permission_denied, message: Exception.message(error)}
  end

  defp to_grpc_error(%Ash.Error.Framework{} = error) do
    %{code: :failed_precondition, message: Exception.message(error)}
  end

  defp to_grpc_error(error) do
    %{code: :internal, message: Exception.message(error)}
  end

  defp field_violations(errors) when is_list(errors) do
    errors
    |> Enum.flat_map(&violations_for_error/1)
    |> Enum.uniq()
  end

  defp field_violations(_errors), do: []

  defp violations_for_error(error) do
    error
    |> error_fields()
    |> Enum.map(fn field ->
      %FieldViolation{field: to_string(field), description: safe_message(error)}
    end)
  end

  defp error_fields(%{field: field}) when not is_nil(field), do: [field]
  defp error_fields(%{fields: fields}) when is_list(fields) and fields != [], do: fields
  defp error_fields(_error), do: []

  defp safe_message(error) do
    Exception.message(error)
  rescue
    _ -> "invalid"
  end

  defp pack_bad_request(violations) do
    Protobuf.Any.pack(%BadRequest{field_violations: violations})
  end
end
