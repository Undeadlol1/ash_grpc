defmodule AshGrpc.Examples.SupportDeskStreaming do
  @moduledoc false

  alias AshGrpc.Examples.SupportDesk

  def submit_ticket_batch(ticket_inputs) do
    with {:ok, tickets} <- create_tickets(ticket_inputs) do
      {:ok, %{submitted_count: length(tickets)}}
    end
  end

  def sync_tickets(ticket_inputs) do
    {:ok,
     Stream.map(ticket_inputs, fn
       {:error, error} -> {:error, error}
       [subject, body] -> build_ticket(subject, body)
     end)}
  end

  defp create_tickets(ticket_inputs) do
    ticket_inputs
    |> Enum.reduce_while({:ok, []}, fn
      {:error, error}, _acc ->
        {:halt, {:error, error}}

      [subject, body], {:ok, tickets} ->
        case build_ticket(subject, body) do
          {:error, error} -> {:halt, {:error, error}}
          ticket -> {:cont, {:ok, [ticket | tickets]}}
        end
    end)
    |> case do
      {:ok, tickets} -> {:ok, Enum.reverse(tickets)}
      {:error, error} -> {:error, error}
    end
  end

  defp build_ticket(subject, body) do
    case SupportDesk.submit_ticket(subject, body) do
      {:ok, ticket} -> ticket
      {:error, error} -> {:error, error}
    end
  end
end
