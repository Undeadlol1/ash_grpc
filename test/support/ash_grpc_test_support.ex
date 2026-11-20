defmodule AshGrpc.TestSupport do
  @moduledoc false

  import AshGrpc.Eventually, only: [eventually: 2]

  defmodule ConnectFailed do
    @moduledoc false
    defexception [:reason]

    @impl true
    def message(%{reason: reason}), do: "could not connect: #{inspect(reason)}"
  end

  @connect_attempts 20
  @connect_backoff_ms 50
  @bind_attempts 10

  @doc """
  Starts the gRPC test server on a port it actually managed to bind.

  `find_free_port/0` can only report a port that was free a moment ago: it has
  to close its probe socket before the caller can bind, so the port is up for
  grabs in between. With an async suite several callers can even be handed the
  same number, and the loser gets `:eaddrinuse`. Retrying with a fresh port is
  the only reliable fix, so prefer this over pairing `find_free_port/0` with
  `start_server_supervisor/1` by hand.
  """
  @spec start_server_on_free_port(keyword()) ::
          {:ok, pos_integer(), pid()} | {:error, term()}
  def start_server_on_free_port(opts \\ []) do
    port_source = Keyword.get(opts, :port_source, &default_port_source/0)

    do_start_server_on_free_port(port_source, @bind_attempts)
  end

  defp do_start_server_on_free_port(port_source, attempts_left) do
    port = port_source.()

    case start_supervisor_without_dying(port) do
      {:ok, supervisor} ->
        {:ok, port, supervisor}

      {:error, reason} when attempts_left > 1 ->
        if address_in_use?(reason) do
          do_start_server_on_free_port(&default_port_source/0, attempts_left - 1)
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_port_source do
    {:ok, port} = find_free_port()
    port
  end

  # Supervisor.start_link/2 links the supervisor to us, so a child that cannot
  # bind takes this process down with it before we get to look at the error.
  # Trap exits for the duration of the attempt so a failed bind is an
  # `{:error, _}` we can retry rather than a dead caller.
  defp start_supervisor_without_dying(port) do
    previously_trapping? = Process.flag(:trap_exit, true)

    try do
      start_server_supervisor(port)
    after
      flush_exit_signals()
      Process.flag(:trap_exit, previously_trapping?)
    end
  end

  defp flush_exit_signals do
    receive do
      {:EXIT, _pid, _reason} -> flush_exit_signals()
    after
      0 -> :ok
    end
  end

  # The bind failure arrives wrapped in several layers of supervisor shutdown
  # tuples, so look for the listen_error anywhere inside the reason.
  defp address_in_use?(:eaddrinuse), do: true

  defp address_in_use?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> address_in_use?()

  defp address_in_use?(reason) when is_list(reason), do: Enum.any?(reason, &address_in_use?/1)
  defp address_in_use?(_reason), do: false

  @spec stop_server(pid()) :: :ok
  def stop_server(supervisor) do
    if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
    :ok
  catch
    :exit, _ -> :ok
  end

  @spec find_free_port() :: {:ok, pos_integer()}
  def find_free_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    {:ok, port}
  end

  @spec start_server_supervisor(pos_integer()) :: {:ok, pid()}
  def start_server_supervisor(port) do
    :ok = ensure_reflection_started()

    Supervisor.start_link(
      [
        {GRPC.Server.Supervisor,
         endpoint: AshGrpc.Router,
         port: port,
         start_server: true,
         adapter_opts: [ip: {127, 0, 0, 1}]}
      ],
      strategy: :one_for_one
    )
  end

  defp ensure_reflection_started do
    case GrpcReflection.Supervisor.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @spec connect_channel(pos_integer()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def connect_channel(port) do
    with :ok <- retry_connecting(fn -> probe_server(port) end, fn _reason -> true end) do
      retry_connecting(
        fn -> GRPC.Stub.connect("127.0.0.1:#{port}") end,
        &(&1 in [:econnrefused, :timeout])
      )
    end
  end

  defp retry_connecting(attempt, retryable?) do
    eventually(
      fn -> raise_if_retryable(attempt.(), retryable?) end,
      attempts: @connect_attempts,
      interval: @connect_backoff_ms,
      retry_if: &match?(%ConnectFailed{}, &1)
    )
  rescue
    error in ConnectFailed -> {:error, error.reason}
  end

  defp raise_if_retryable({:error, reason} = error, retryable?) do
    if retryable?.(reason), do: raise(ConnectFailed, reason: reason), else: error
  end

  defp raise_if_retryable(result, _retryable?), do: result

  defp probe_server(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 100) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        :ok

      {:error, _reason} = error ->
        error
    end
  end
end
