defmodule AshGrpc.Deadline do
  @moduledoc """
  Parses the gRPC `grpc-timeout` request header into an Ash action timeout.

  gRPC clients express their deadline as `grpc-timeout: <value><unit>` where
  unit is one of `H`, `M`, `S`, `m`, `u`, `n` (hours…nanoseconds). Honoring
  it lets the server stop working on a request the client has already given
  up on — the deadline-propagation half of the gRPC contract. The parsed
  value is fed to Ash as a millisecond `:timeout`, so a long-running action
  is cancelled at (or before) the client's deadline.

  Sub-millisecond deadlines are rounded up to 1 ms, the finest granularity
  Ash timeouts express. A missing or malformed header yields `:none` and the
  request runs without a gRPC-derived timeout (the domain default applies).
  """

  @header "grpc-timeout"
  @max_digits 8

  @unit_to_ms %{
    "H" => 3_600_000,
    "M" => 60_000,
    "S" => 1_000,
    "m" => 1
  }

  @spec timeout_option(map()) :: {:timeout, pos_integer()} | :none
  def timeout_option(headers) when is_map(headers) do
    case parse(Map.get(headers, @header)) do
      {:ok, milliseconds} -> {:timeout, milliseconds}
      :none -> :none
    end
  end

  @spec parse(String.t() | nil) :: {:ok, pos_integer()} | :none
  def parse(nil), do: :none

  def parse(value) when is_binary(value) do
    with {digits, unit} when digits != "" <- String.split_at(value, -1),
         true <- valid_digits?(digits),
         {:ok, milliseconds} <- to_milliseconds(digits, unit) do
      {:ok, milliseconds}
    else
      {"", _unit} -> :none
      false -> :none
      :error -> :none
    end
  end

  defp valid_digits?(digits) do
    String.length(digits) <= @max_digits and String.match?(digits, ~r/\A\d+\z/)
  end

  defp to_milliseconds(digits, unit) do
    amount = String.to_integer(digits)

    cond do
      Map.has_key?(@unit_to_ms, unit) ->
        {:ok, max(amount * @unit_to_ms[unit], 1)}

      # Microseconds and nanoseconds are below Ash's millisecond resolution;
      # any positive sub-millisecond deadline rounds up to 1 ms.
      unit in ["u", "n"] and amount > 0 ->
        {:ok, 1}

      true ->
        :error
    end
  end
end
