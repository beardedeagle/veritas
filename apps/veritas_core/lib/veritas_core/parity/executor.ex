defmodule Veritas.Core.Parity.Executor do
  @moduledoc """
  Runs trusted BEAM proof workers under an invocation-owned lifetime channel.

  Before evaluating candidate code, every inherited BEAM joins the same private
  loopback channel. Timeout, caller cancellation or channel loss stops workers;
  the supervisor waits for their channels and the root exit before returning.
  The existing datastore guardian retains responsibility for its native store:
  it observes root stdin closing, stops the store, then closes its own channel.

  This is a cooperative lifecycle protocol for the project's tests, not an OS
  sandbox for arbitrary untrusted native programs. Test-owned native resources
  retain their existing explicit cleanup contracts.
  """

  # Each BEAM joins before candidate code runs. The connection is both a
  # cancellation channel and a lifetime receipt, including nested BEAMs.
  @bootstrap """
  {ok,S}=gen_tcp:connect({127,0,0,1},list_to_integer(os:getenv("VERITAS_PARITY_PORT")),[binary,{active,false},{packet,4}],5000),
  ok=gen_tcp:send(S,list_to_binary(os:getenv("VERITAS_PARITY_TOKEN"))),
  case gen_tcp:recv(S,0,5000) of
    {ok,<<"run">>} ->
      P=spawn(fun()->receive {watch,C}->
        gen_tcp:recv(C,0,infinity),
        case os:getenv("VERITAS_STORE_COMMAND") of
          false->erlang:halt(143);
          _->receive after infinity->ok end
        end
      end end),
      ok=gen_tcp:controlling_process(S,P),P!{watch,S};
    _->erlang:halt(143)
  end.
  """

  @output_limit 1_048_576

  @doc "Whether the configured BEAM entry-point executable is present."
  @spec available?(term()) :: boolean()
  def available?(executable), do: is_binary(executable) and File.regular?(executable)

  @doc "Runs a worker and returns output, exit status and confirmed successful lifecycle."
  @spec run(Path.t(), [String.t()], Path.t(), pos_integer()) ::
          {String.t(), integer() | nil, boolean()}
  def run(executable, args, cwd, timeout) do
    caller = self()
    {worker, ref} = spawn_monitor(fn -> supervise(caller, executable, args, cwd, timeout) end)

    receive do
      {^worker, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^worker, reason} ->
        {"proof supervisor failed: #{inspect(reason)}", nil, false}
    end
  end

  defp supervise(caller, executable, args, cwd, timeout) do
    owner = Process.monitor(caller)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])
    {:ok, number} = :inet.port(listener)
    token = :crypto.strong_rand_bytes(24) |> Base.encode16(case: :lower)
    supervisor = self()
    acceptor = spawn_link(fn -> accept(listener, supervisor) end)
    chars = @bootstrap |> String.to_charlist() |> Enum.join(",")

    bootstrap =
      "erl_eval:exprs(element(2,erl_parse:parse_exprs(element(2,erl_scan:string([#{chars}])))),[])."

    flags = System.get_env("ERL_AFLAGS", "") <> " -eval " <> bootstrap

    try do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: args,
          cd: cwd,
          env: [
            {~c"ERL_AFLAGS", String.to_charlist(flags)},
            {~c"VERITAS_PARITY_PORT", Integer.to_charlist(number)},
            {~c"VERITAS_PARITY_TOKEN", String.to_charlist(token)},
            {~c"MIX_ENV", ~c"test"}
          ]
        ])

      result =
        loop(%{
          port: port,
          listener: listener,
          owner: owner,
          token: token,
          clients: MapSet.new(),
          root_client: nil,
          output: [],
          output_bytes: 0,
          status: nil,
          stopping: false,
          timed_out: false,
          deadline: now() + timeout,
          joined: false
        })

      send(caller, {self(), result})
    rescue
      error -> send(caller, {self(), {Exception.message(error), nil, false}})
    after
      :gen_tcp.close(listener)
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
      Process.demonitor(owner, [:flush])
    end
  end

  defp accept(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, parent)
        send(parent, {:client, socket})
        accept(listener, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp loop(state) do
    cond do
      now() >= state.deadline ->
        expire(state)

      state.stopping and state.status != nil and MapSet.size(state.clients) == 0 ->
        {state.output |> Enum.reverse() |> IO.iodata_to_binary(), state.status,
         state.joined and not state.timed_out}

      true ->
        receive do
          {:client, socket} ->
            case :gen_tcp.recv(socket, 0, 1_000) do
              {:ok, token} when token == state.token ->
                :ok = :inet.setopts(socket, active: true)
                :ok = :gen_tcp.send(socket, if(state.stopping, do: "stop", else: "run"))

                loop(%{
                  state
                  | clients: MapSet.put(state.clients, socket),
                    root_client: state.root_client || socket,
                    joined: true
                })

              _ ->
                :gen_tcp.close(socket)
                loop(state)
            end

          {:tcp_closed, socket} ->
            loop(client_closed(state, socket))

          {:tcp_error, socket, reason} ->
            :gen_tcp.close(socket)

            loop(
              client_closed(
                %{state | timed_out: state.timed_out or reason not in [:closed, :econnreset]},
                socket
              )
            )

          {port, {:data, bytes}} when port == state.port ->
            if state.output_bytes + byte_size(bytes) > @output_limit do
              loop(stop(%{state | timed_out: true}))
            else
              loop(%{
                state
                | output: [bytes | state.output],
                  output_bytes: state.output_bytes + byte_size(bytes)
              })
            end

          {port, {:exit_status, status}} when port == state.port ->
            loop(stop(%{state | status: status}))

          {:DOWN, ref, :process, _caller, _reason} when ref == state.owner ->
            loop(stop(%{state | timed_out: true}))
        after
          max(state.deadline - now(), 0) ->
            expire(state)
        end
    end
  end

  defp expire(%{stopping: true} = state) do
    if Port.info(state.port), do: Port.close(state.port)
    Enum.each(state.clients, &:gen_tcp.close/1)
    {state.output |> Enum.reverse() |> IO.iodata_to_binary(), nil, false}
  end

  defp expire(state), do: loop(stop(%{state | timed_out: true}))

  defp client_closed(state, socket) do
    next = %{state | clients: MapSet.delete(state.clients, socket)}
    # A descendant can retain a root output pipe. Do not wait for pipe EOF
    # before stopping it: the root lifetime channel is the completion signal.
    if socket == state.root_client, do: stop(next), else: next
  end

  defp stop(%{stopping: true} = state), do: state

  defp stop(state) do
    Enum.each(state.clients, &:gen_tcp.send(&1, "stop"))
    %{state | stopping: true, deadline: now() + 5_000}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
