defmodule AshGrpc.AuthenticatorTest do
  use ExUnit.Case, async: true

  alias AshGrpc.Authenticator
  alias AshGrpc.MetadataContext

  defmodule BearerAuthenticator do
    @moduledoc false
    @behaviour Authenticator

    @impl Authenticator
    def authenticate(headers, _options) do
      case Map.get(headers, "authorization") do
        "Bearer valid-token" -> {:ok, %{id: "server-derived-user"}}
        nil -> :anonymous
        _invalid -> {:error, "invalid token"}
      end
    end
  end

  describe "GIVEN the actor behind a grpc call WHEN the authenticator is asked for the actor" do
    test "THEN the actor is nil when no authenticator is configured" do
      assert {:ok, nil} = Authenticator.authenticate(nil, %{}, [])
    end

    test "THEN the actor is nil when the authenticator reports anonymous" do
      assert {:ok, nil} = Authenticator.authenticate(BearerAuthenticator, %{}, [])
    end

    test "THEN the call fails as unauthenticated when the authenticator rejects the credentials" do
      headers = %{"authorization" => "Bearer nope"}

      assert {:error, %{code: :unauthenticated, message: "invalid token"}} =
               Authenticator.authenticate(BearerAuthenticator, headers, [])
    end
  end

  describe "GIVEN the actor behind a grpc call WHEN verified credentials are merged into action options" do
    test "THEN the actor is derived on the server from verified credentials" do
      metadata = %{"authorization" => "Bearer valid-token"}

      assert {:ok, opts} =
               MetadataContext.merge_action_options(
                 authenticator: BearerAuthenticator,
                 metadata: metadata
               )

      assert Keyword.get(opts, :actor) == %{id: "server-derived-user"}
    end

    test "THEN the server-derived actor overrides a client-supplied x-ash-actor" do
      metadata = %{
        "authorization" => "Bearer valid-token",
        "x-ash-actor" => Jason.encode!(%{"id" => "attacker"})
      }

      assert {:ok, opts} =
               MetadataContext.merge_action_options(
                 authenticator: BearerAuthenticator,
                 actor_resolver: AshGrpc.AuthenticatorTest.PassthroughResolver,
                 metadata: metadata
               )

      assert Keyword.get(opts, :actor) == %{id: "server-derived-user"}
    end

    test "THEN an explicit actor option still wins over the authenticator" do
      metadata = %{"authorization" => "Bearer valid-token"}

      assert {:ok, opts} =
               MetadataContext.merge_action_options(
                 authenticator: BearerAuthenticator,
                 actor: %{id: "explicit-caller"},
                 metadata: metadata
               )

      assert Keyword.get(opts, :actor) == %{id: "explicit-caller"}
    end

    test "THEN the request is rejected when credentials are invalid" do
      metadata = %{"authorization" => "Bearer nope"}

      assert {:error, %{code: :unauthenticated}} =
               MetadataContext.merge_action_options(
                 authenticator: BearerAuthenticator,
                 metadata: metadata
               )
    end

    test "THEN an anonymous request passes through with a nil actor" do
      assert {:ok, opts} =
               MetadataContext.merge_action_options(
                 authenticator: BearerAuthenticator,
                 metadata: %{}
               )

      assert Keyword.get(opts, :actor) == nil
    end
  end

  defmodule PassthroughResolver do
    @moduledoc false
    def resolve(%{"id" => id}), do: {:ok, %{id: id}}
  end
end
