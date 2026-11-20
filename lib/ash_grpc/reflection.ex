defmodule AshGrpc.Reflection do
  @moduledoc """
  Builds protobuf descriptors from a domain's gRPC routes, and queries a running
  server's reflection service. `AshGrpc.ProtoExporter` renders the descriptors
  as `.proto` source.
  """

  alias AshGrpc.Domain.Info
  alias Google.Protobuf.DescriptorProto
  alias Google.Protobuf.FieldDescriptorProto
  alias Google.Protobuf.FileDescriptorProto
  alias Google.Protobuf.FileDescriptorSet
  alias Google.Protobuf.MethodDescriptorProto
  alias Google.Protobuf.MethodOptions
  alias Google.Protobuf.ServiceDescriptorProto
  alias Grpc.Reflection.V1.ServerReflection.Stub, as: ReflectionStub
  alias Grpc.Reflection.V1.ServerReflectionRequest

  @field_type_mapping %{
    double: :TYPE_DOUBLE,
    float: :TYPE_FLOAT,
    int64: :TYPE_INT64,
    uint64: :TYPE_UINT64,
    int32: :TYPE_INT32,
    fixed64: :TYPE_FIXED64,
    fixed32: :TYPE_FIXED32,
    bool: :TYPE_BOOL,
    string: :TYPE_STRING,
    bytes: :TYPE_BYTES,
    uint32: :TYPE_UINT32,
    sfixed32: :TYPE_SFIXED32,
    sfixed64: :TYPE_SFIXED64,
    sint32: :TYPE_SINT32,
    sint64: :TYPE_SINT64
  }

  def describe_endpoint(endpoint) do
    Enum.map(endpoint.__meta__(:servers), fn server_module ->
      service_module = server_module.__meta__(:service)
      service = describe_rpc_service(service_module)
      Map.put(service, :server, server_module)
    end)
  end

  def describe_domain(domain, options) do
    service_modules = service_modules!(options)
    domain_services = Info.routes(domain)

    Enum.map(service_modules, fn service_module ->
      describe_service(domain, domain_services, service_module)
    end)
  end

  def descriptor_set(domain, options) do
    %FileDescriptorSet{
      file: Enum.map(describe_domain(domain, options), &describe_file_descriptor/1)
    }
  end

  def list_services(channel) do
    request = %ServerReflectionRequest{message_request: {:list_services, ""}}

    with {:ok, response} <- request_reflection(channel, request),
         {:list_services_response, list_services_response} <- response.message_response do
      {:ok, Enum.map(list_services_response.service, & &1.name)}
    end
  end

  def file_containing_symbol(channel, symbol) when is_binary(symbol) do
    request = %ServerReflectionRequest{message_request: {:file_containing_symbol, symbol}}

    with {:ok, response} <- request_reflection(channel, request) do
      decode_file_descriptor_response(response)
    end
  end

  defp request_reflection(channel, request) do
    stream = ReflectionStub.server_reflection_info(channel)
    stream = GRPC.Stub.send_request(stream, request, end_stream: true)

    with {:ok, responses} <- GRPC.Stub.recv(stream),
         {:ok, response} <- first_reflection_response(responses) do
      case response.message_response do
        {:error_response, error} -> {:error, error.error_message}
        _message_response -> {:ok, response}
      end
    end
  end

  defp first_reflection_response(responses) do
    responses
    |> Enum.take(1)
    |> case do
      [{:ok, response}] -> {:ok, response}
      [{:error, error}] -> {:error, error.message}
      [] -> {:error, "reflection server returned no response"}
    end
  end

  defp decode_file_descriptor_response(response) do
    case response.message_response do
      {:file_descriptor_response, file_descriptor_response} ->
        case file_descriptor_response.file_descriptor_proto do
          [encoded_descriptor | _rest] -> {:ok, FileDescriptorProto.decode(encoded_descriptor)}
          [] -> {:error, "reflection server returned no file descriptor"}
        end

      _message_response ->
        {:error, "reflection server returned the wrong response type"}
    end
  end

  defp service_modules!(options) do
    cond do
      service_module = Keyword.get(options, :service) ->
        [service_module]

      service_modules = Keyword.get(options, :services) ->
        service_modules

      true ->
        raise ArgumentError, "expected :service or :services option"
    end
  end

  defp describe_service(domain, domain_services, service_module) do
    service = describe_rpc_service(service_module)
    rpc_calls = service_module.__rpc_calls__()
    domain_service = find_domain_service!(domain, domain_services, service_module, rpc_calls)
    routes_by_name = Map.new(domain_service.routes, &{&1.name, &1})

    Map.merge(service, %{
      path: domain_service.path,
      domain: domain,
      methods: Enum.map(service.methods, &enrich_method(&1, routes_by_name, domain))
    })
  end

  defp describe_rpc_service(service_module) do
    service_name = service_module.__meta__(:name)

    %{
      service: service_module,
      service_name: service_name,
      methods: Enum.map(service_module.__rpc_calls__(), &describe_rpc_method(&1, service_name))
    }
  end

  defp find_domain_service!(domain, domain_services, service_module, rpc_calls) do
    expected_route_names = MapSet.new(rpc_calls, &rpc_route_name/1)

    Enum.find(domain_services, fn service ->
      route_names = MapSet.new(Enum.map(service.routes, & &1.name))
      route_names == expected_route_names
    end) ||
      raise ArgumentError,
            "could not match #{inspect(service_module)} to an ash_grpc service declared on #{inspect(domain)}"
  end

  defp enrich_method(method, routes_by_name, domain) do
    route = Map.fetch!(routes_by_name, method.name)

    Map.merge(method, %{
      domain: domain,
      handler: Map.get(route, :handler) || domain,
      resource: route.resource,
      action: route.action,
      deprecated: Map.get(route, :deprecated)
    })
  end

  defp describe_rpc_method(rpc_call, service_name) do
    {request_module, request_stream?} = elem(rpc_call, 1)
    {response_module, response_stream?} = elem(rpc_call, 2)
    rpc_name = elem(rpc_call, 0)

    %{
      name: rpc_route_name(rpc_call),
      rpc_name: rpc_name,
      grpc_path: "/#{service_name}/#{rpc_name}",
      kind: GRPC.Service.grpc_type(rpc_call),
      request: describe_message(request_module, request_stream?),
      response: describe_message(response_module, response_stream?),
      options: GRPC.Service.rpc_options(rpc_call)
    }
  end

  defp describe_file_descriptor(service) do
    %FileDescriptorProto{
      name: descriptor_file_name(service.service_name),
      package: descriptor_package(service.service_name),
      syntax: "proto3",
      message_type: describe_message_descriptors(service.methods),
      service: [describe_service_descriptor(service)]
    }
  end

  defp describe_service_descriptor(service) do
    %ServiceDescriptorProto{
      name: descriptor_service_name(service.service_name),
      method: Enum.map(service.methods, &describe_method_descriptor/1)
    }
  end

  defp describe_method_descriptor(method) do
    %MethodDescriptorProto{
      name: to_string(method.rpc_name),
      input_type: qualify_type_name(method.request.full_name, method.request.module),
      output_type: qualify_type_name(method.response.full_name, method.response.module),
      client_streaming: method.request.stream?,
      server_streaming: method.response.stream?,
      options: describe_method_options(method)
    }
  end

  defp describe_method_options(%{deprecated: deprecated}) when is_binary(deprecated) do
    %MethodOptions{deprecated: true}
  end

  defp describe_method_options(_method), do: nil

  defp describe_message_descriptors(methods) do
    methods
    |> Enum.flat_map(&[&1.request.module, &1.response.module])
    |> Enum.uniq()
    |> Enum.map(&describe_message_descriptor/1)
  end

  defp describe_message_descriptor(module) do
    props = module.__message_props__()
    repeated_fields = MapSet.new(props.repeated_fields)

    %DescriptorProto{
      name: descriptor_name(full_name(module), module),
      field: Enum.map(props.ordered_tags, &describe_field_descriptor(props, repeated_fields, &1))
    }
  end

  defp describe_field_descriptor(props, repeated_fields, tag) do
    field = Map.fetch!(props.field_props, tag)
    {type, type_name} = descriptor_field_type(field.type)

    %FieldDescriptorProto{
      name: to_string(field.name_atom),
      number: tag,
      json_name: field.json_name,
      label: descriptor_field_label(repeated_fields, tag),
      type: type,
      type_name: type_name
    }
  end

  defp descriptor_field_label(repeated_fields, tag) do
    if MapSet.member?(repeated_fields, tag) do
      :LABEL_REPEATED
    else
      :LABEL_OPTIONAL
    end
  end

  defp descriptor_field_type(type) when is_atom(type) do
    case Map.fetch(@field_type_mapping, type) do
      {:ok, mapped_type} -> {mapped_type, nil}
      :error -> {:TYPE_MESSAGE, qualify_type_name(nil, type)}
    end
  end

  defp descriptor_file_name(service_name) do
    package = descriptor_package(service_name)
    service = service_name |> descriptor_service_name() |> Macro.underscore()

    package
    |> String.replace(".", "/")
    |> Path.join("#{service}.proto")
  end

  defp descriptor_package(service_name) do
    service_name
    |> String.split(".")
    |> Enum.drop(-1)
    |> Enum.join(".")
  end

  defp descriptor_service_name(service_name) do
    service_name
    |> String.split(".")
    |> List.last()
  end

  defp descriptor_name(nil, module), do: module |> Module.split() |> List.last()

  defp descriptor_name(full_name, _module) do
    full_name
    |> String.split(".")
    |> List.last()
  end

  defp qualify_type_name(nil, module) do
    "." <> (full_name(module) || Enum.join(Module.split(module), "."))
  end

  defp qualify_type_name(full_name, _module), do: "." <> full_name

  defp describe_message(module, stream?) do
    props = module.__message_props__()
    repeated_fields = MapSet.new(props.repeated_fields)

    %{
      module: module,
      full_name: full_name(module),
      stream?: stream?,
      fields: Enum.map(props.ordered_tags, &describe_field(props, repeated_fields, &1))
    }
  end

  defp describe_field(props, repeated_fields, tag) do
    field = Map.fetch!(props.field_props, tag)

    %{
      number: tag,
      name: field.name_atom,
      json_name: field.json_name,
      type: field.type,
      repeated?: MapSet.member?(repeated_fields, tag)
    }
  end

  defp full_name(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :full_name, 0) do
      module.full_name()
    end
  end

  defp rpc_route_name(rpc_call) do
    rpc_call
    |> elem(0)
    |> to_string()
    |> Macro.underscore()
    |> String.to_atom()
  end
end
