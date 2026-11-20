defmodule AshGrpc.HealthTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.Health.HealthCheckRequest
  alias AshGrpc.Health.HealthCheckResponse
  alias AshGrpc.TestSupport.Endpoint
  alias AshGrpc.TestSupport.HealthEndpoint
  alias AshGrpc.TestSupport.HealthEndpoint.Blog.V1, as: PostsV1
  alias AshGrpc.TestSupport.HealthEndpoint.Blog.V1.Posts.Stub, as: PostsStub
  alias GRPC.RPCError
  alias GRPC.Status

  defmodule Stub do
    @moduledoc false
    use GRPC.Stub, service: AshGrpc.Health.Service
  end

  defp check(channel, service) do
    Stub.check(channel, %HealthCheckRequest{service: service})
  end

  describe "health on" do
    setup do
      %{channel: start(HealthEndpoint)}
    end

    test "an empty service name is SERVING without credentials", %{channel: channel} do
      assert {:ok, %HealthCheckResponse{status: :SERVING}} = check(channel, "")
    end

    test "every service the endpoint serves is SERVING", %{channel: channel} do
      assert {:ok, %HealthCheckResponse{status: :SERVING}} = check(channel, "blog.v1.Posts")
      assert {:ok, %HealthCheckResponse{status: :SERVING}} = check(channel, "library.v1.Library")
    end

    test "an unknown service name is NOT_FOUND", %{channel: channel} do
      assert {:error, %RPCError{status: status}} = check(channel, "no.such.Service")
      assert status == Status.not_found()
    end

    test "watching sends the current status once and stays open", %{channel: channel} do
      {:ok, replies} = Stub.watch(channel, %HealthCheckRequest{service: "blog.v1.Posts"})

      assert [{:ok, %HealthCheckResponse{status: :SERVING}}] = Enum.take(replies, 1)
    end

    test "watching an unknown service sends SERVICE_UNKNOWN", %{channel: channel} do
      {:ok, replies} = Stub.watch(channel, %HealthCheckRequest{service: "no.such.Service"})

      assert [{:ok, %HealthCheckResponse{status: :SERVICE_UNKNOWN}}] = Enum.take(replies, 1)
    end

    test "the other services still ask for credentials", %{channel: channel} do
      assert {:error, %RPCError{status: status}} =
               PostsStub.list_posts(channel, %PostsV1.ListPostsRequest{})

      assert status == Status.unauthenticated()
    end
  end

  describe "health off" do
    test "calling the health service finds no such route (HTTP 404)" do
      channel = start(Endpoint)

      assert {:error, %RPCError{message: message}} = check(channel, "")
      assert message =~ "404"
    end
  end
end
