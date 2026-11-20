defmodule AshGrpc.ReadWireFieldsTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.Vault.Account
  alias AshGrpc.TestSupport.Vault.Entry
  alias AshGrpc.TestSupport.VaultEndpoint
  alias AshGrpc.TestSupport.VaultEndpoint.Vault.V1
  alias AshGrpc.TestSupport.VaultEndpoint.Vault.V1.Vault.Stub
  alias AshGrpc.Types
  alias Google.Rpc.BadRequest
  alias GRPC.RPCError
  alias GRPC.Status

  setup do
    channel = start(VaultEndpoint)
    owner = "account#{System.unique_integer([:positive])}"

    account =
      Account
      |> Ash.Changeset.for_create(:create, %{name: owner, email: "a@x.io", api_token: "s3cret"})
      |> Ash.create!()

    Entry
    |> Ash.Changeset.for_create(:create, %{label: "open", memo: "hush", account_id: account.id})
    |> Ash.create!()

    %{channel: channel, metadata: signed_in("anyone"), owner: owner}
  end

  defp search(channel, metadata, request),
    do:
      Stub.search_accounts(channel, struct(V1.SearchAccountsRequest, request), metadata: metadata)

  defp assert_refused(result, name) do
    assert {:error, %RPCError{status: status, details: [detail | _]}} = result
    assert status == Status.invalid_argument()

    assert %BadRequest{field_violations: [%{field: field, description: description}]} =
             BadRequest.decode(detail.value)

    assert description =~ name
    assert field in ["filter", "sort"]
  end

  test "a filter on a hidden or sensitive field is INVALID_ARGUMENT naming it", %{
    channel: channel,
    metadata: metadata
  } do
    for {name, filter} <- [
          {"api_token", %{"api_token" => %{"greater_than" => "s3"}}},
          {"email", %{"email" => %{"contains" => "@x.io"}}},
          {"api_token", %{"and" => [%{"name" => "a"}, %{"api_token" => "s3cret"}]}},
          {"api_token", %{"or" => [%{"api_token" => "s3cret"}]}},
          {"api_token", %{"not" => %{"api_token" => "s3cret"}}},
          {"api_token", %{"not" => %{"or" => [%{"and" => [%{"api_token" => %{"eq" => "x"}}]}]}}}
        ] do
      assert_refused(
        search(channel, metadata, filter: Types.encode(:struct, filter)),
        name
      )
    end
  end

  test "a filter through a relationship may use only the fields the related message carries", %{
    channel: channel,
    metadata: metadata,
    owner: owner
  } do
    allowed =
      Types.encode(:struct, %{
        "name" => owner,
        "entries" => %{"label" => %{"eq" => "open"}}
      })

    hidden = Types.encode(:struct, %{"entries" => %{"memo" => %{"eq" => "hush"}}})

    assert {:ok, %{result: [%{name: ^owner}]}} = search(channel, metadata, filter: allowed)
    assert_refused(search(channel, metadata, filter: hidden), "memo")
  end

  test "a sort by a hidden or sensitive field is INVALID_ARGUMENT naming it", %{
    channel: channel,
    metadata: metadata
  } do
    for {name, sort} <- [
          {"api_token", "api_token"},
          {"api_token", "-api_token"},
          {"api_token", "name,api_token"},
          {"email", "++email"}
        ] do
      assert_refused(search(channel, metadata, sort: sort), name)
    end
  end

  test "a subscription refuses a filter or sort on a hidden field", %{
    channel: channel,
    metadata: metadata
  } do
    filter = Types.encode(:struct, %{"api_token" => %{"greater_than" => "s3"}})

    for request <- [
          %V1.WatchAccountsRequest{filter: filter},
          %V1.WatchAccountsRequest{sort: "api_token"}
        ] do
      assert {:ok, replies} =
               Stub.watch_accounts(channel, request, metadata: metadata, timeout: 2_000)

      assert {:error, %RPCError{status: status}} = Enum.find(replies, &match?({:error, _}, &1))
      assert status == Status.invalid_argument()
    end
  end

  test "fields on the wire still filter and sort", %{
    channel: channel,
    metadata: metadata,
    owner: owner
  } do
    filter = Types.encode(:struct, %{"name" => %{"eq" => owner}})

    assert {:ok, %{result: [%{name: ^owner}]}} =
             search(channel, metadata, filter: filter, sort: "-name")
  end
end
