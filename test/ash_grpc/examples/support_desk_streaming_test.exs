defmodule AshGrpc.Examples.SupportDeskStreamingTest do
  use ExUnit.Case, async: true

  import AshGrpc.TestHelpers, only: [maybe_sort_subjects: 2, unique_integer: 0]

  alias AshGrpc.Examples.SupportDesk
  alias AshGrpc.Examples.SupportDeskStreaming
  alias AshGrpc.Examples.SupportTicket

  describe "GIVEN the support desk streaming" do
    test "WHEN a batch of valid tickets is submitted THEN the submitted count is two" do
      unique_suffix = unique_integer()

      assert {:ok, %{submitted_count: 2}} =
               SupportDeskStreaming.submit_ticket_batch(ticket_inputs(unique_suffix))
    end

    test "WHEN a batch has an invalid item THEN submission stops at that item with an invalid argument error" do
      unique_suffix = unique_integer()

      assert {:error, %{code: :invalid_argument, message: "subject and body are required"}} =
               SupportDeskStreaming.submit_ticket_batch(
                 ticket_inputs_with_invalid_item(unique_suffix)
               )
    end

    test "WHEN a batch has an invalid item THEN only the items before it are persisted" do
      unique_suffix = unique_integer()

      assert {:error, %{code: :invalid_argument, message: "subject and body are required"}} =
               SupportDeskStreaming.submit_ticket_batch(
                 ticket_inputs_with_invalid_item(unique_suffix)
               )

      assert persisted_subjects(unique_suffix, sort?: false) == [
               "printer broken #{unique_suffix}"
             ]
    end

    test "WHEN valid tickets are synced THEN two created tickets are returned" do
      unique_suffix = unique_integer()

      assert {:ok, replies} = SupportDeskStreaming.sync_tickets(ticket_inputs(unique_suffix))

      created_tickets = Enum.to_list(replies)

      assert length(created_tickets) == 2
      assert Enum.all?(created_tickets, &match?(%SupportTicket{}, &1))
    end

    test "WHEN a synced stream has an invalid item THEN the replies keep the item order" do
      unique_suffix = unique_integer()

      assert {:ok, replies} =
               SupportDeskStreaming.sync_tickets(ticket_inputs_with_invalid_item(unique_suffix))

      assert_invalid_streamed_item_sequence(replies)
    end

    test "WHEN a synced stream has an invalid item THEN the created tickets are persisted in order around it" do
      unique_suffix = unique_integer()

      assert {:ok, replies} =
               SupportDeskStreaming.sync_tickets(ticket_inputs_with_invalid_item(unique_suffix))

      assert_invalid_streamed_item_sequence(replies)

      assert persisted_subjects(unique_suffix, sort?: true) ==
               Enum.sort(["printer broken #{unique_suffix}", "scanner jam #{unique_suffix}"])
    end
  end

  defp ticket_inputs(unique_suffix) do
    [
      ["printer broken #{unique_suffix}", "paper jam #{unique_suffix}"],
      ["scanner jam #{unique_suffix}", "toner spill #{unique_suffix}"]
    ]
  end

  defp ticket_inputs_with_invalid_item(unique_suffix) do
    [
      ["printer broken #{unique_suffix}", "paper jam #{unique_suffix}"],
      invalid_stream_item(),
      ["scanner jam #{unique_suffix}", "toner spill #{unique_suffix}"]
    ]
  end

  defp invalid_stream_item do
    {:error, %{code: :invalid_argument, message: "subject and body are required"}}
  end

  defp assert_invalid_streamed_item_sequence(replies) do
    assert [
             %SupportTicket{},
             {:error, %{code: :invalid_argument, message: "subject and body are required"}},
             %SupportTicket{}
           ] = Enum.to_list(replies)
  end

  defp persisted_subjects(unique_suffix, options) do
    assert {:ok, tickets} = SupportDesk.stream_tickets()

    tickets
    |> Enum.map(& &1.subject)
    |> Enum.filter(&String.ends_with?(&1, " #{unique_suffix}"))
    |> maybe_sort_subjects(options)
  end
end
