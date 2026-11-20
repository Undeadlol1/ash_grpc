defmodule AshGrpc.ProtoExporter do
  @moduledoc """
  Renders the `google.protobuf.FileDescriptorProto`s that `AshGrpc.Reflection`
  already builds from a domain's gRPC routes into `.proto` source text.

  This is the codegen half of the integration: reflection serves descriptors
  at runtime, but a client in another language (Dart, Swift, ...) is generated
  from exported `.proto` files. `mix ash_grpc.gen.protos` uses
  this module to write those files to disk.

  Only the constructs ash_grpc's descriptors use are rendered (proto3
  syntax, package, messages with scalar/message/enum fields incl. repeated,
  and services with unary/streaming RPCs). It is a faithful serializer of
  the descriptor set, not a general-purpose protobuf printer.
  """

  alias Google.Protobuf.DescriptorProto
  alias Google.Protobuf.FieldDescriptorProto
  alias Google.Protobuf.FileDescriptorProto
  alias Google.Protobuf.MethodDescriptorProto
  alias Google.Protobuf.ServiceDescriptorProto

  @scalar_types %{
    TYPE_DOUBLE: "double",
    TYPE_FLOAT: "float",
    TYPE_INT64: "int64",
    TYPE_UINT64: "uint64",
    TYPE_INT32: "int32",
    TYPE_FIXED64: "fixed64",
    TYPE_FIXED32: "fixed32",
    TYPE_BOOL: "bool",
    TYPE_STRING: "string",
    TYPE_BYTES: "bytes",
    TYPE_UINT32: "uint32",
    TYPE_SFIXED32: "sfixed32",
    TYPE_SFIXED64: "sfixed64",
    TYPE_SINT32: "sint32",
    TYPE_SINT64: "sint64"
  }

  @spec to_proto_source(struct()) :: String.t()
  def to_proto_source(%FileDescriptorProto{} = file) do
    sections =
      Enum.reject(
        [
          ~s(syntax = "#{file.syntax || "proto3"}";),
          package_line(file.package),
          messages_block(file.message_type),
          services_block(file.service)
        ],
        &(&1 in [nil, ""])
      )

    Enum.join(sections, "\n\n") <> "\n"
  end

  defp package_line(nil), do: nil
  defp package_line(""), do: nil
  defp package_line(package), do: "package #{package};"

  defp messages_block([]), do: nil
  defp messages_block(messages), do: Enum.map_join(messages, "\n\n", &message/1)

  defp message(%DescriptorProto{name: name, field: fields}) do
    body = Enum.map_join(fields, "\n", &"  #{field(&1)}")

    if body == "" do
      "message #{name} {}"
    else
      "message #{name} {\n#{body}\n}"
    end
  end

  defp field(%FieldDescriptorProto{} = field) do
    "#{label(field.label)}#{field_type(field)} #{field.name} = #{field.number};"
  end

  defp label(:LABEL_REPEATED), do: "repeated "
  defp label(_other), do: ""

  defp field_type(%FieldDescriptorProto{type: type, type_name: type_name}) do
    case Map.fetch(@scalar_types, type) do
      {:ok, scalar} -> scalar
      :error -> normalize_type_name(type_name)
    end
  end

  # Descriptor type names are fully qualified with a leading dot; proto
  # source references them without it.
  defp normalize_type_name("." <> rest), do: rest
  defp normalize_type_name(name) when is_binary(name), do: name

  defp services_block([]), do: nil
  defp services_block(services), do: Enum.map_join(services, "\n\n", &service/1)

  defp service(%ServiceDescriptorProto{name: name, method: methods}) do
    body = Enum.map_join(methods, "\n", &"  #{method(&1)}")

    "service #{name} {\n#{body}\n}"
  end

  defp method(%MethodDescriptorProto{} = method) do
    "rpc #{method.name} (#{stream(method.client_streaming)}#{normalize_type_name(method.input_type)})" <>
      " returns (#{stream(method.server_streaming)}#{normalize_type_name(method.output_type)});"
  end

  defp stream(true), do: "stream "
  defp stream(_false), do: ""
end
