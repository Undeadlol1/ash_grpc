defmodule AshGrpc.ReflectionTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Endpoint
  alias AshGrpc.TestSupport.HealthReflectionEndpoint
  alias AshGrpc.TestSupport.ReflectionEndpoint
  alias Google.Protobuf.FileDescriptorProto
  alias Grpc.Reflection.V1.ServerReflection.Stub
  alias Grpc.Reflection.V1.ServerReflectionRequest
  alias Grpc.Reflection.V1alpha.ServerReflection.Stub, as: StubAlpha
  alias Grpc.Reflection.V1alpha.ServerReflectionRequest, as: RequestAlpha
  alias GRPC.RPCError
  alias GRPC.Status

  defp ask(channel, request, headers \\ signed_in("reader"), stub \\ Stub) do
    stream = stub.server_reflection_info(channel, metadata: headers)
    GRPC.Stub.send_request(stream, request, end_stream: true)
    {:ok, replies} = GRPC.Stub.recv(stream)
    [{:ok, %{message_response: response}}] = Enum.to_list(replies)
    response
  end

  defp list_services(channel) do
    {:list_services_response, %{service: services}} =
      ask(channel, %ServerReflectionRequest{message_request: {:list_services, ""}})

    Enum.map(services, & &1.name)
  end

  defp file_with(channel, symbol) do
    {:file_descriptor_response, %{file_descriptor_proto: [bytes]}} =
      ask(channel, %ServerReflectionRequest{message_request: {:file_containing_symbol, symbol}})

    FileDescriptorProto.decode(bytes)
  end

  defp message_numbers(endpoint, package, message) do
    {_path, text} = Enum.find(AshGrpc.Proto.render(endpoint), &(elem(&1, 0) =~ package))
    [_, body] = Regex.run(~r/message #{message} \{\n(.*?)\n\}/s, text)

    for [_, name, number] <- Regex.scan(~r/(\w+) = (\d+)/, body), into: %{} do
      {name, String.to_integer(number)}
    end
  end

  defp field_numbers(%FileDescriptorProto{message_type: messages}, message) do
    descriptor = Enum.find(messages, &(&1.name == message))
    Map.new(descriptor.field, &{&1.name, &1.number})
  end

  describe "reflection with health on" do
    setup do
      %{channel: start(HealthReflectionEndpoint)}
    end

    test "listing services includes the health service", %{channel: channel} do
      assert "grpc.health.v1.Health" in list_services(channel)
    end

    test "the health service can be described by symbol", %{channel: channel} do
      assert %FileDescriptorProto{service: [%{name: "Health"}]} =
               file_with(channel, "grpc.health.v1.Health")
    end
  end

  describe "reflection with health on, the answer type" do
    setup do
      %{channel: start(HealthReflectionEndpoint)}
    end

    test "can be resolved, so a client can read the serving status", %{channel: channel} do
      assert {:file_descriptor_response, %{file_descriptor_proto: files}} =
               ask(
                 channel,
                 %ServerReflectionRequest{
                   message_request:
                     {:file_containing_symbol, "grpc.health.v1.HealthCheckResponse.ServingStatus"}
                 }
               )

      nested_enums =
        for bytes <- files,
            %{name: "HealthCheckResponse", enum_type: enums} <-
              FileDescriptorProto.decode(bytes).message_type,
            enum <- enums,
            do: enum.name

      assert nested_enums == ["ServingStatus"]
    end
  end

  describe "reflection on" do
    setup do
      %{channel: start(ReflectionEndpoint)}
    end

    test "listing services returns every service of both domains and the reflection service", %{
      channel: channel
    } do
      services = list_services(channel)

      assert "blog.v1.Posts" in services
      assert "library.v1.Library" in services
      assert "grpc.reflection.v1.ServerReflection" in services
    end

    test "the older v1alpha service lists the same services", %{channel: channel} do
      {:list_services_response, %{service: services}} =
        ask(
          channel,
          %RequestAlpha{message_request: {:list_services, ""}},
          signed_in("reader"),
          StubAlpha
        )

      names = Enum.map(services, & &1.name)
      assert "blog.v1.Posts" in names
      assert "library.v1.Library" in names
    end

    test "describing a service returns its rpcs including a server-streaming subscription", %{
      channel: channel
    } do
      file = file_with(channel, "library.v1.Library")
      [service] = file.service
      methods = Map.new(service.method, &{&1.name, &1})

      assert service.name == "Library"
      assert Map.has_key?(methods, "ListBooks")
      assert methods["ListBooks"].server_streaming in [false, nil]
      assert methods["WatchBooks"].server_streaming == true
    end

    test "describing a message returns its field names and numbers, with a nested message and a relationship",
         %{channel: channel} do
      file = file_with(channel, "library.v1.Book")
      expected = message_numbers(ReflectionEndpoint, "library", "Book")
      book = Enum.find(file.message_type, &(&1.name == "Book"))
      author = Enum.find(book.field, &(&1.name == "author"))

      assert field_numbers(file, "Book") == expected
      assert author.type_name == ".library.v1.Author"
    end

    test "describing a message returns an enum field with its number", %{channel: channel} do
      file = file_with(channel, "blog.v1.Post")
      expected = message_numbers(ReflectionEndpoint, "blog", "Post")
      status = file.message_type |> Enum.find(&(&1.name == "Post")) |> Map.fetch!(:field)
      status = Enum.find(status, &(&1.name == "status"))

      assert field_numbers(file, "Post") == expected
      assert status.number == expected["status"]
      assert status.type_name == ".blog.v1.PostStatus"
    end

    test "an unknown symbol answers the reflection error response", %{channel: channel} do
      response =
        ask(channel, %ServerReflectionRequest{
          message_request: {:file_containing_symbol, "no.Such"}
        })

      assert {:error_response, %{error_code: code}} = response
      assert code == Status.not_found()
    end

    test "a call without credentials is UNAUTHENTICATED", %{channel: channel} do
      stream = Stub.server_reflection_info(channel)

      GRPC.Stub.send_request(
        stream,
        %ServerReflectionRequest{message_request: {:list_services, ""}},
        end_stream: true
      )

      assert {:error, %RPCError{status: status}} = GRPC.Stub.recv(stream)
      assert status == Status.unauthenticated()
    end
  end

  describe "reflection off" do
    test "calling the reflection service finds no such route (HTTP 404)" do
      channel = start(Endpoint)
      stream = Stub.server_reflection_info(channel, metadata: signed_in("reader"))

      GRPC.Stub.send_request(
        stream,
        %ServerReflectionRequest{message_request: {:list_services, ""}},
        end_stream: true
      )

      assert {:error, %RPCError{message: message}} = GRPC.Stub.recv(stream)
      assert message =~ "404"
    end
  end

  describe "the dependency is missing" do
    test "the build stops with the hint to add grpc_reflection" do
      error = assert_raise ArgumentError, fn -> AshGrpc.Endpoint.ensure_reflection!(false) end

      assert error.message =~ ~s({:grpc_reflection, "~> 0.5"})
      assert AshGrpc.Endpoint.ensure_reflection!(true) == :ok
    end
  end
end
