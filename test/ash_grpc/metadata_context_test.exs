defmodule AshGrpc.MetadataContextActorResolver do
  @moduledoc false

  def resolve(%{"id" => actor_id}) when is_binary(actor_id), do: {:ok, %{id: actor_id}}
end

defmodule AshGrpc.MetadataContextFakeAdapter do
  @moduledoc false

  def get_headers(%{headers: headers}), do: headers
end

defmodule AshGrpc.MetadataContextTest do
  use ExUnit.Case, async: true

  alias AshGrpc.MetadataContext

  defp stream_with_headers(headers) do
    %GRPC.Server.Stream{
      adapter: AshGrpc.MetadataContextFakeAdapter,
      payload: %{headers: headers}
    }
  end

  describe "GIVEN the metadata context WHEN a network stream carries metadata" do
    test "THEN reserved x-ash headers from an untrusted stream are rejected" do
      stream =
        stream_with_headers(%{
          "x-ash-authorize" => "false",
          "content-type" => "application/grpc"
        })

      assert {:error, %{code: :permission_denied, message: message}} =
               MetadataContext.merge_action_options(grpc_stream: stream)

      assert message =~ "not trusted"
    end

    test "THEN non-reserved headers from an untrusted stream are ignored" do
      stream = stream_with_headers(%{"content-type" => "application/grpc"})

      assert {:ok, opts} = MetadataContext.merge_action_options(grpc_stream: stream)
      assert Keyword.get(opts, :authorize?) == nil
      assert Keyword.get(opts, :actor) == nil
    end

    test "THEN reserved headers are honored when the endpoint trusts request metadata" do
      stream =
        stream_with_headers(%{
          "x-ash-authorize" => "false",
          "x-ash-tenant" => "tenant-1"
        })

      assert {:ok, opts} =
               MetadataContext.merge_action_options(
                 grpc_stream: stream,
                 trust_request_metadata: true
               )

      assert Keyword.get(opts, :authorize?) == false
      assert Keyword.get(opts, :tenant) == "tenant-1"
    end
  end

  describe "GIVEN the metadata context" do
    test "WHEN reserved grpc metadata is given THEN it maps to Ash actor, authorize, context and tenant options" do
      metadata = %{
        "x-ash-actor" => Jason.encode!(%{"id" => "grpc-user"}),
        "x-ash-authorize" => "true",
        "x-ash-context" => Jason.encode!(%{"locale" => "en"}),
        "x-ash-tenant" => "tenant-1"
      }

      assert {:ok, opts} =
               MetadataContext.merge_action_options(
                 actor_resolver: AshGrpc.MetadataContextActorResolver,
                 metadata: metadata
               )

      assert Keyword.get(opts, :actor) == %{id: "grpc-user"}
      assert Keyword.get(opts, :authorize?) == true
      assert Keyword.get(opts, :context) == %{"locale" => "en"}
      assert Keyword.get(opts, :tenant) == "tenant-1"
    end

    test "WHEN explicit Ash options conflict with metadata THEN the explicit options win" do
      metadata = %{
        "x-ash-authorize" => "false",
        "x-ash-context" => Jason.encode!(%{"locale" => "en"}),
        "x-ash-tenant" => "tenant-1"
      }

      assert {:ok, opts} =
               MetadataContext.merge_action_options(
                 authorize?: true,
                 context: %{locale: "kk"},
                 metadata: metadata,
                 tenant: "tenant-2"
               )

      assert Keyword.get(opts, :authorize?) == true
      assert Keyword.get(opts, :context) == %{locale: "kk"}
      assert Keyword.get(opts, :tenant) == "tenant-2"
    end

    test "WHEN the authorize metadata is neither true nor false THEN the request is rejected as invalid argument" do
      metadata = %{"x-ash-authorize" => "sometimes"}

      assert {:error, %{code: :invalid_argument, message: message}} =
               MetadataContext.merge_action_options(metadata: metadata)

      assert message == "x-ash-authorize must be true or false"
    end

    test "WHEN actor metadata arrives without an actor resolver THEN the request is rejected as invalid argument" do
      metadata = %{"x-ash-actor" => Jason.encode!(%{"id" => "grpc-user"})}

      assert {:error, %{code: :invalid_argument, message: message}} =
               MetadataContext.merge_action_options(metadata: metadata)

      assert message == "x-ash-actor requires an ash_grpc actor resolver"
    end
  end
end
