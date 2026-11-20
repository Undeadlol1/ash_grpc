defmodule AshGrpc.Eventually do
  @moduledoc false

  @default_timeout_ms 5_000
  @default_interval_ms 25

  def eventually(fun, options \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(options, :timeout, @default_timeout_ms)
    interval = Keyword.get(options, :interval, @default_interval_ms)
    retry_if = Keyword.get(options, :retry_if, &match?(%ExUnit.AssertionError{}, &1))
    attempts = Keyword.get(options, :attempts, :infinity)

    deadline = if timeout == :infinity, do: :infinity, else: now() + timeout
    attempt(fun, %{deadline: deadline, interval: interval, retry_if: retry_if}, attempts)
  end

  defp attempt(fun, plan, attempts_left) do
    case run(fun) do
      {:ok, value} ->
        value

      {:error, error, stacktrace} ->
        if plan.retry_if.(error) and attempts_left != 1 and time_left?(plan) do
          :timer.sleep(plan.interval)
          attempt(fun, plan, count_down(attempts_left))
        else
          reraise error, stacktrace
        end
    end
  end

  defp time_left?(%{deadline: :infinity}), do: true
  defp time_left?(%{deadline: deadline, interval: interval}), do: now() + interval < deadline

  defp count_down(:infinity), do: :infinity
  defp count_down(attempts_left), do: attempts_left - 1

  defp run(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error, __STACKTRACE__}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
