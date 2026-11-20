defmodule AshGrpc.FieldNumbers do
  @moduledoc false

  alias Spark.Error.DslError

  @highest 536_870_911
  @protobuf_only 19_000..19_999

  def names(fields), do: Enum.map(fields, &name/1)

  defp name({name, _number}), do: name
  defp name(name), do: name

  def validate(fields, module, path) do
    names = names(fields)
    numbers = for {_name, number} <- fields, do: number

    cond do
      Enum.any?(numbers, &(not (is_integer(&1) and &1 > 0))) ->
        bad = for {name, number} <- fields, not (is_integer(number) and number > 0), do: name
        error(module, path, "Field numbers must be positive integers; not for #{inspect(bad)}.")

      duplicates(names) != [] ->
        error(module, path, "Field names repeat: #{inspect(duplicates(names))}.")

      duplicates(numbers) != [] ->
        error(module, path, "Field numbers repeat: #{inspect(duplicates(numbers))}.")

      true ->
        :ok
    end
  end

  def validate_reserved(reserved, numbers, module, path, who \\ "") do
    used = Enum.filter(reserved, &(&1 in numbers))

    cond do
      duplicates(reserved) != [] ->
        error(
          module,
          path,
          "#{who}Reserved numbers repeat: #{inspect(duplicates(reserved), charlists: :as_lists)}."
        )

      used != [] ->
        error(
          module,
          path,
          "#{who}Field numbers #{inspect(used, charlists: :as_lists)} are reserved and cannot be used."
        )

      true ->
        :ok
    end
  end

  @doc """
  The `{name, number}` list and the sorted reserved numbers of a resource
  message. Explicit numbers are kept, a name in the committed message keeps its
  number there, and the rest get the lowest free number above everything the
  message has used (from 1 when nothing was committed). Committed numbers no
  longer in use become reserved. `committed` is `:unconfigured`, or
  `{relative_path, text | nil}` for the package's committed `.proto` file.
  """
  def assign(resource, message, fields, reserved, committed) do
    if Enum.all?(fields, &is_tuple/1) do
      {fields, Enum.sort(reserved)}
    else
      previous = committed_message(resource, message, committed)
      assign_automatic(resource, message, fields, reserved, previous)
    end
  end

  defp assign_automatic(resource, message, fields, reserved, previous) do
    old = previous || %{fields: %{}, reserved: []}
    committed_by_name = Map.new(old.fields, fn {number, field} -> {field.name, number} end)

    unnumbered =
      for name when is_atom(name) <- fields, into: MapSet.new(), do: Atom.to_string(name)

    explicit = for {_name, number} <- fields, do: number

    for {name, number} <- fields,
        %{name: owner} <- [old.fields[number]],
        owner != Atom.to_string(name) and MapSet.member?(unnumbered, owner) do
      raise_error(
        resource,
        "#{message}: field #{inspect(name)} is pinned to #{number}, which the committed file " <>
          "gives to `#{owner}`, still listed without a number. Pin `#{owner}` to another number " <>
          "or give #{inspect(name)} a free one."
      )
    end

    with {:error, error} <-
           validate_reserved(old.reserved, explicit, resource, [:grpc, :fields], "#{message}: ") do
      raise error
    end

    used = explicit ++ Map.keys(old.fields) ++ old.reserved ++ reserved
    floor = if previous, do: Enum.max(used, fn -> 0 end), else: 0

    {numbered, _acc} =
      Enum.map_reduce(fields, {MapSet.new(used), floor}, fn
        {name, number}, acc ->
          {{name, number}, acc}

        name, {used, floor} ->
          number =
            Map.get_lazy(committed_by_name, Atom.to_string(name), fn ->
              free(resource, message, name, floor + 1, used)
            end)

          {{name, number}, {MapSet.put(used, number), max(floor, number)}}
      end)

    taken = for {_name, number} <- numbered, do: number
    retired = Map.keys(old.fields) -- taken

    {numbered, Enum.sort(Enum.uniq(reserved ++ old.reserved ++ retired))}
  end

  defp free(resource, message, name, number, _used) when number > @highest do
    raise_error(resource, "#{message}: no free field number left for #{inspect(name)}.")
  end

  defp free(resource, message, name, number, used) when number in @protobuf_only,
    do: free(resource, message, name, @protobuf_only.last + 1, used)

  defp free(resource, message, name, number, used) do
    if MapSet.member?(used, number),
      do: free(resource, message, name, number + 1, used),
      else: number
  end

  defp committed_message(resource, message, :unconfigured) do
    raise_error(
      resource,
      "#{message} has fields without a number, so AshGrpc picks them and keeps them in the " <>
        "committed .proto files, since a field's number must stay the same between builds. " <>
        "Tell it where those files live:\n\n" <>
        ~s(    config :ash_grpc, proto_output: "priv/protos")
    )
  end

  defp committed_message(_resource, _message, {_file, nil}), do: nil

  defp committed_message(resource, message, {file, text}) do
    AshGrpc.Proto.Compatibility.parse(text).messages[message]
  rescue
    error in ArgumentError ->
      raise_error(
        resource,
        "#{message}: the committed #{file} in `proto_output` cannot be read: #{error.message}"
      )
  end

  defp raise_error(resource, message),
    do: raise(DslError, module: resource, path: [:grpc, :fields], message: message)

  def error(module, path, message) do
    {:error, DslError.exception(module: module, path: path, message: message)}
  end

  defp duplicates(list), do: Enum.uniq(list -- Enum.uniq(list))
end
