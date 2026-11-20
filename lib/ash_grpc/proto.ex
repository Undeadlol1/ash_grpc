defmodule AshGrpc.Proto do
  @moduledoc """
  Renders the `.proto` files of an endpoint (or a list of domains): one file
  per domain package, from the same model the server is compiled from.
  """

  alias AshGrpc.Types

  @doc "A list of `{relative_path, text}`, one per package."
  @spec render(module() | [module()], keyword()) :: [{String.t(), String.t()}]
  def render(domains, opts \\ [])

  def render(domains, opts) when is_list(domains), do: files(AshGrpc.Schema.build(domains, opts))

  def render(endpoint, _opts) when is_atom(endpoint), do: endpoint.__ash_grpc__(:protos)

  @doc false
  def files(packages), do: for(package <- packages, do: {package.file, package_text(package)})

  defp package_text(package) do
    messages =
      package.messages ++
        for service <- package.services,
            rpc <- service.rpcs,
            message <- AshGrpc.Schema.rpc_messages(rpc),
            do: message

    sections = [
      ~s(syntax = "proto3";),
      "package #{package.package};",
      imports(messages),
      Enum.map_join(package.enums, "\n\n", &(&1 |> enum_text() |> Enum.join("\n"))),
      Enum.map_join(messages, "\n\n", &(&1 |> message_text() |> Enum.join("\n"))),
      Enum.map_join(package.services, "\n\n", &service_text/1)
    ]

    sections |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n") |> Kernel.<>("\n")
  end

  @well_known %{
    rpc_status: ~s(import "google/rpc/status.proto";),
    timestamp: ~s(import "google/protobuf/timestamp.proto";),
    struct: ~s(import "google/protobuf/struct.proto";)
  }

  defp imports(messages) do
    kinds = for message <- messages, field <- message.fields, do: field.kind

    @well_known
    |> Enum.sort()
    |> Enum.filter(fn {kind, _line} -> kind in kinds end)
    |> Enum.map_join("\n", fn {_kind, line} -> line end)
  end

  defp enum_text(enum) do
    values =
      Enum.flat_map(enum.values, fn value ->
        comment(value.description, "  ") ++ ["  #{value.name} = #{value.number};"]
      end)

    ["enum #{enum.name} {" | values] ++ ["}"]
  end

  defp message_text(message) do
    comment(message[:description], "") ++ [message_body(message)]
  end

  defp message_body(%{name: name, fields: [], reserved: []}), do: "message #{name} {}"

  defp message_body(message) do
    reserved =
      case message.reserved do
        [] -> []
        numbers -> ["  reserved #{Enum.join(numbers, ", ")};"]
      end

    fields = Enum.map(message.fields, &field_lines/1)

    body =
      cond do
        Map.get(message, :oneof?, false) ->
          ["  oneof value {" | Enum.map(fields, &indent(&1, "    "))] ++ ["  }"] ++ reserved

        Enum.any?(message.fields, & &1[:oneof]) ->
          grouped_body(message.fields) ++ reserved

        true ->
          Enum.map(fields, &indent(&1, "  ")) ++ reserved
      end

    "message #{message.name} {\n#{Enum.join(body, "\n")}\n}"
  end

  defp grouped_body(fields) do
    fields
    |> Enum.chunk_by(& &1[:oneof])
    |> Enum.flat_map(fn
      [%{oneof: name} | _] = members ->
        ["  oneof #{name} {" | Enum.map(members, &indent(field_lines(&1), "    "))] ++ ["  }"]

      members ->
        Enum.map(members, &indent(field_lines(&1), "  "))
    end)
  end

  defp indent(lines, prefix), do: Enum.map_join(lines, "\n", &(prefix <> &1))

  defp comment(nil, _prefix), do: []
  defp comment("", _prefix), do: []

  defp comment(description, prefix) do
    for line <- String.split(description, ~r/\R/),
        do: String.trim_trailing(prefix <> "// " <> line)
  end

  defp field_lines(field) do
    comment(Map.get(field, :description), "") ++ [field_text(field)]
  end

  defp field_text(field) do
    label =
      cond do
        field.repeated? -> "repeated "
        field.optional? and not Types.message?(field.kind) -> "optional "
        true -> ""
      end

    option = if Map.get(field, :deprecated?), do: " [deprecated = true]", else: ""

    "#{label}#{Types.proto_type(field.kind)} #{field.name} = #{field.number}#{option};"
  end

  defp stream_prefix(nil), do: ""
  defp stream_prefix(_streaming), do: "stream "

  defp reply_stream_prefix(%{streaming: :client}), do: ""
  defp reply_stream_prefix(%{streaming: :bidirectional}), do: "stream "
  defp reply_stream_prefix(%{stream?: true}), do: "stream "
  defp reply_stream_prefix(_rpc), do: ""

  defp reply_name(%{streaming: :bidirectional, proto_name: name}), do: name <> "Reply"
  defp reply_name(%{streaming: :client, proto_name: name}), do: name <> "Summary"
  defp reply_name(rpc), do: rpc.response.name

  defp service_text(service) do
    rpcs =
      Enum.map_join(service.rpcs, "\n", fn rpc ->
        signature =
          "  rpc #{rpc.proto_name}(#{stream_prefix(rpc.streaming)}#{rpc.request.name}) " <>
            "returns (#{reply_stream_prefix(rpc)}#{reply_name(rpc)})"

        definition =
          if rpc.deprecated?,
            do: signature <> " {\n    option deprecated = true;\n  }",
            else: signature <> ";"

        Enum.join(comment(rpc[:description], "  ") ++ [definition], "\n")
      end)

    "service #{service.name} {\n#{rpcs}\n}"
  end
end
