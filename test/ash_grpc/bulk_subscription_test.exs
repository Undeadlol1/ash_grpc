defmodule AshGrpc.BulkSubscriptionTest do
  use ExUnit.Case, async: false

  import AshGrpc.TestSupport.GrpcServer

  alias AshGrpc.TestSupport.BulkEndpoint
  alias AshGrpc.TestSupport.BulkEndpoint.Bulk.V1, as: Bulk
  alias AshGrpc.TestSupport.BulkEndpoint.Bulk.V1.Memos.Stub
  alias AshGrpc.TestSupport.Memo

  setup do
    owner = "owner#{System.unique_integer([:positive])}"
    channel = start(BulkEndpoint)
    test = self()

    spawn_link(fn ->
      {:ok, replies} =
        Stub.watch_memos(channel, %Bulk.WatchMemosRequest{},
          metadata: signed_in(owner),
          timeout: 5_000
        )

      Enum.each(replies, &send(test, {:reply, &1}))
    end)

    assert_receive {:reply, {:ok, %{synced: true}}}, 2_000
    %{channel: channel, owner: owner}
  end

  test "a bulk create reaches an open subscription", %{channel: channel, owner: owner} do
    request = %Bulk.CreateMemosRequest{
      inputs: [%Bulk.CreateMemosInput{title: "first"}, %Bulk.CreateMemosInput{title: "second"}]
    }

    assert {:ok, %{result: [_first, _second]}} =
             Stub.create_memos(channel, request, metadata: signed_in(owner))

    assert_receive {:reply, {:ok, %{removed: false, result: %{title: first}}}}, 2_000
    assert_receive {:reply, {:ok, %{removed: false, result: %{title: second}}}}, 2_000
    assert Enum.sort([first, second]) == ["first", "second"]
  end

  test "a bulk destroy reaches an open subscription", %{channel: channel, owner: owner} do
    memo =
      Memo
      |> Ash.Changeset.for_create(:create, %{title: "doomed"}, actor: %{name: owner})
      |> Ash.create!()

    assert_receive {:reply, {:ok, %{removed: false, result: %{id: id}}}}, 2_000
    assert id == memo.id

    request = %Bulk.DeleteMemosRequest{ids: [memo.id]}
    metadata = signed_in(owner, %{"x-role" => "admin"})

    assert {:ok, _reply} = Stub.delete_memos(channel, request, metadata: metadata)

    assert_receive {:reply, {:ok, %{removed: true, result: %{id: ^id}}}}, 2_000
  end
end
