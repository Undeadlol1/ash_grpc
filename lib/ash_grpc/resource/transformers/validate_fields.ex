defmodule AshGrpc.Resource.Transformers.ValidateFields do
  @moduledoc false

  # A transformer, not a verifier: Spark turns a verifier error into a warning.

  use Spark.Dsl.Transformer

  alias AshGrpc.Resource.Info
  alias Spark.Dsl.Transformer

  def after?(_transformer), do: true

  def transform(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    listed = Info.listed_fields(dsl_state)
    fields = listed || []

    with :ok <- verify_hidden(dsl_state, module, listed),
         :ok <- AshGrpc.FieldNumbers.validate(fields, module, [:grpc, :fields]),
         {:ok, reserved} <- Info.grpc_reserved(dsl_state),
         :ok <-
           AshGrpc.FieldNumbers.validate_reserved(
             reserved,
             for({_name, number} <- fields, do: number),
             module,
             [:grpc, :reserved]
           ),
         names =
           if(listed, do: AshGrpc.FieldNumbers.names(fields), else: default_names(dsl_state)),
         {:ok, deprecated} <- Info.grpc_deprecated(dsl_state),
         :ok <- verify_deprecated(module, deprecated, names),
         :ok <- Enum.find_value(names, :ok, &verify_listed(dsl_state, module, listed, &1)) do
      {:ok, put_default_message(dsl_state, module)}
    end
  end

  defp default_names(dsl_state),
    do: Info.public_field_names(dsl_state) -- Info.grpc_hide_fields!(dsl_state)

  defp verify_listed(_dsl_state, _module, nil, _name), do: nil
  defp verify_listed(dsl_state, module, _listed, name), do: problem(dsl_state, module, name)

  defp verify_hidden(dsl_state, module, listed) do
    {:ok, hidden} = Info.grpc_hide_fields(dsl_state)

    cond do
      hidden == [] ->
        :ok

      listed ->
        AshGrpc.FieldNumbers.error(
          module,
          [:grpc, :hide_fields],
          "`hide_fields` cannot be used together with `fields`: `fields` already says which fields are sent. Use one or the other."
        )

      true ->
        verify_hidden_are_public(dsl_state, module, hidden)
    end
  end

  defp verify_hidden_are_public(dsl_state, module, hidden) do
    case hidden -- Info.public_field_names(dsl_state) do
      [] ->
        :ok

      unknown ->
        AshGrpc.FieldNumbers.error(
          module,
          [:grpc, :hide_fields],
          "`hide_fields` names #{inspect(unknown)}, which are not public attributes, calculations, aggregates or relationships of this resource."
        )
    end
  end

  defp put_default_message(dsl_state, module) do
    case Info.grpc_proto_message(dsl_state) do
      {:ok, _name} ->
        dsl_state

      :error ->
        name = module |> Module.split() |> List.last()
        Transformer.set_option(dsl_state, [:grpc], :proto_message, name)
    end
  end

  defp verify_deprecated(module, deprecated, names) do
    case Enum.reject(deprecated, &(&1 in names)) do
      [] ->
        :ok

      unknown ->
        AshGrpc.FieldNumbers.error(
          module,
          [:grpc, :deprecated],
          "`deprecated` names #{inspect(unknown)}, which are not in `fields`."
        )
    end
  end

  @doc false
  def problem(dsl_state, module, name) do
    case Info.field(dsl_state, name) do
      nil ->
        verify_relationship(dsl_state, module, name)

      %{public?: false} ->
        field_error(module, "Field #{inspect(name)} is not public (`public?: true`).")

      %{sensitive?: true} ->
        field_error(module, "Field #{inspect(name)} is sensitive and cannot be sent.")

      field ->
        with nil <- required_argument_error(module, name, field) do
          case AshGrpc.Types.field_kind(name, field.type, field.constraints) do
            {:ok, _kind} -> nil
            {:error, message} -> field_error(module, message)
          end
        end
    end
  end

  defp verify_relationship(dsl_state, module, name) do
    case Ash.Resource.Info.relationship(dsl_state, name) do
      nil ->
        field_error(
          module,
          "`fields` names #{inspect(name)}, which is not an attribute, calculation, aggregate or relationship of this resource."
        )

      %{public?: false} ->
        field_error(module, "Field #{inspect(name)} is not public (`public?: true`).")

      _relationship ->
        nil
    end
  end

  defp required_argument_error(module, name, %Ash.Resource.Calculation{arguments: arguments}) do
    case Enum.find(arguments, &(not &1.allow_nil? and is_nil(&1.default))) do
      nil ->
        nil

      argument ->
        field_error(
          module,
          "Calculation #{inspect(name)} requires argument #{inspect(argument.name)}, " <>
            "which a field cannot supply. Give the argument a default or `allow_nil? true`."
        )
    end
  end

  defp required_argument_error(_module, _name, _field), do: nil

  defp field_error(module, message),
    do: AshGrpc.FieldNumbers.error(module, [:grpc, :fields], message)
end
