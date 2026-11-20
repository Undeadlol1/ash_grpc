defmodule AshGrpc.Proto.Compatibility do
  @moduledoc """
  Tells whether regenerating a `.proto` file would break clients built from the
  committed one.

      AshGrpc.Proto.Compatibility.check(committed_text, new_text)
      #=> :ok | ["message Post: field 3 ... was removed ..."]

  Breaking: a field number that now means something else (name, type,
  optional or repeated), a field that is gone without its number being
  `reserved`, a `reserved` number that is free again or in use, a message,
  service, rpc or subscription that is gone, an rpc whose request or response
  type changed, and a unary rpc that became a stream or the reverse (on either side).
  Enums: a value removed or renumbered, or an enum that is gone, is breaking; a
  value added is fine. Adding things, marking things deprecated and retiring a field by reserving
  its number are fine, and so is any change to a `//` comment line.

  It parses only the text `AshGrpc.Proto` renders and raises `ArgumentError`
  on anything else, rather than guessing.
  """

  @field ~r/^  (?:(optional|repeated) )?([\w.]+) (\w+) = (\d+)(?: \[deprecated = true\])?;$/
  @reserved ~r/^  reserved (\d+(?:, \d+)*);$/
  @rpc ~r/^  rpc (\w+)\(((?:stream )?\w+)\) returns \(((?:stream )?\w+)\)( \{|;)$/
  @ignored [~r/^$/, ~r/^syntax = "proto3";$/, ~r/^package [\w.]+;$/, ~r/^import "[\w\/.]+";$/]

  @doc "`:ok`, or one sentence per breaking change."
  @spec check(String.t(), String.t()) :: :ok | [String.t()]
  def check(old_text, new_text) do
    old = parse(old_text)
    new = parse(new_text)

    case enum_changes(old.enums, new.enums) ++
           message_changes(old.messages, new.messages) ++
           service_changes(old.services, new.services) do
      [] -> :ok
      changes -> changes
    end
  end

  defp enum_changes(old, new) do
    Enum.flat_map(Enum.sort(old), fn {name, old_values} ->
      case Map.fetch(new, name) do
        {:ok, new_values} -> value_changes(name, old_values, new_values)
        :error -> ["enum #{name} was removed."]
      end
    end)
  end

  defp value_changes(name, old, new) do
    Enum.flat_map(Enum.sort(old), fn {number, value} ->
      case Map.fetch(new, number) do
        {:ok, ^value} ->
          []

        {:ok, other} ->
          ["enum #{name}: value #{number} changed from `#{value}` to `#{other}`."]

        :error ->
          ["enum #{name}: value #{number} (`#{value}`) was removed."]
      end
    end)
  end

  defp message_changes(old, new) do
    Enum.flat_map(Enum.sort(old), fn {name, old_message} ->
      case Map.fetch(new, name) do
        {:ok, new_message} -> field_changes(name, old_message, new_message)
        :error -> ["message #{name} was removed."]
      end
    end)
  end

  defp field_changes(name, old, new) do
    fields =
      Enum.flat_map(Enum.sort(old.fields), fn {number, old_field} ->
        case Map.fetch(new.fields, number) do
          {:ok, ^old_field} ->
            []

          {:ok, new_field} ->
            [
              "message #{name}: field #{number} changed from `#{describe(old_field)}` " <>
                "to `#{describe(new_field)}`. Give the new meaning a new number and " <>
                "add `reserved #{number}` to #{name}."
            ]

          :error ->
            if number in new.reserved do
              []
            else
              [
                "message #{name}: field #{number} (`#{describe(old_field)}`) was removed " <>
                  "but its number is not reserved. Add `reserved #{number}` to #{name}."
              ]
            end
        end
      end)

    reserved =
      for number <- Enum.sort(old.reserved), number not in new.reserved do
        if Map.has_key?(new.fields, number) do
          "message #{name}: reserved number #{number} is used by a field again."
        else
          "message #{name}: reserved number #{number} is no longer reserved. " <>
            "Keep `reserved #{number}` in #{name}."
        end
      end

    fields ++ reserved
  end

  defp describe(%{label: label, type: type, name: name}) do
    Enum.join(Enum.reject([label, type, name], &(&1 == "")), " ")
  end

  defp service_changes(old, new) do
    Enum.flat_map(Enum.sort(old), fn {name, rpcs} ->
      case Map.fetch(new, name) do
        {:ok, new_rpcs} -> rpc_changes(name, rpcs, new_rpcs)
        :error -> ["service #{name} was removed."]
      end
    end)
  end

  defp rpc_changes(service, old, new) do
    Enum.flat_map(Enum.sort(old), fn {name, types} ->
      case Map.fetch(new, name) do
        {:ok, ^types} ->
          []

        {:ok, {request, response}} ->
          {old_request, old_response} = types

          [
            "service #{service}: rpc #{name} changed from " <>
              "(#{old_request}) returns (#{old_response}) to (#{request}) returns (#{response})."
          ]

        :error ->
          ["service #{service}: rpc #{name} was removed."]
      end
    end)
  end

  @doc false
  def parse(text) do
    {_context, schema} =
      text
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce({:top, %{messages: %{}, services: %{}, enums: %{}}}, &parse_line/2)

    schema
  end

  defp parse_line({line, number}, {context, schema}) do
    if comment?(line) do
      {context, schema}
    else
      case line_event(context, line) do
        {:ok, update} -> update.({context, schema})
        :error -> raise ArgumentError, "cannot read .proto line #{number}: #{inspect(line)}"
      end
    end
  end

  defp comment?(line), do: String.starts_with?(String.trim_leading(line), "//")

  defp line_event(:top, line) do
    cond do
      Enum.any?(@ignored, &Regex.match?(&1, line)) ->
        {:ok, & &1}

      match = Regex.run(~r/^enum (\w+) \{$/, line) ->
        [_, name] = match
        {:ok, fn {_c, s} -> {{:enum, name}, put_in(s.enums[name], %{})} end}

      match = Regex.run(~r/^message (\w+) \{\}$/, line) ->
        [_, name] = match
        {:ok, fn {c, s} -> {c, put_message(s, name)} end}

      match = Regex.run(~r/^message (\w+) \{$/, line) ->
        [_, name] = match
        {:ok, fn {_c, s} -> {{:message, name}, put_message(s, name)} end}

      match = Regex.run(~r/^service (\w+) \{$/, line) ->
        [_, name] = match
        {:ok, fn {_c, s} -> {{:service, name}, put_in(s.services[name], %{})} end}

      true ->
        :error
    end
  end

  defp line_event({:enum, name}, line) do
    cond do
      line == "}" ->
        {:ok, fn {_c, s} -> {:top, s} end}

      match = Regex.run(~r/^  (\w+) = (\d+);$/, line) ->
        [_, value, number] = match
        {:ok, fn {c, s} -> {c, put_in(s.enums[name][String.to_integer(number)], value)} end}

      true ->
        :error
    end
  end

  defp line_event({:oneof, name}, "  }"), do: {:ok, fn {_c, s} -> {{:message, name}, s} end}

  defp line_event({:oneof, name}, "  " <> member), do: line_event({:message, name}, member)
  defp line_event({:oneof, _name}, _line), do: :error

  defp line_event({:message, name}, line) do
    cond do
      line == "}" ->
        {:ok, fn {_c, s} -> {:top, s} end}

      Regex.match?(~r/^  oneof \w+ \{$/, line) ->
        {:ok, fn {_c, s} -> {{:oneof, name}, s} end}

      match = Regex.run(@field, line) ->
        [_, label, type, field_name, number] = match
        field = %{label: label, type: type, name: field_name}

        {:ok, fn {c, s} -> {c, put_field(s, name, String.to_integer(number), field)} end}

      match = Regex.run(@reserved, line) ->
        [_, numbers] = match
        reserved = numbers |> String.split(", ") |> Enum.map(&String.to_integer/1)
        {:ok, fn {c, s} -> {c, update_in(s.messages[name].reserved, &(&1 ++ reserved))} end}

      true ->
        :error
    end
  end

  defp line_event({:service, name}, line) do
    cond do
      line == "}" ->
        {:ok, fn {_c, s} -> {:top, s} end}

      match = Regex.run(@rpc, line) ->
        [_, rpc, request, response, ending] = match
        next = if ending == ";", do: {:service, name}, else: {:rpc, name}
        {:ok, fn {_c, s} -> {next, put_in(s.services[name][rpc], {request, response})} end}

      true ->
        :error
    end
  end

  defp line_event({:rpc, service}, line) do
    cond do
      line == "    option deprecated = true;" -> {:ok, & &1}
      line == "  }" -> {:ok, fn {_c, s} -> {{:service, service}, s} end}
      true -> :error
    end
  end

  defp put_field(schema, message, number, field) do
    case schema.messages[message].fields do
      %{^number => other} ->
        raise ArgumentError,
              "message #{message} uses number #{number} for both `#{other.name}` and `#{field.name}`"

      _ ->
        put_in(schema.messages[message].fields[number], field)
    end
  end

  defp put_message(schema, name), do: put_in(schema.messages[name], %{fields: %{}, reserved: []})
end
