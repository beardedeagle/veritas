defmodule Veritas.Core.WorkspaceLockTest do
  use ExUnit.Case, async: false

  alias Veritas.Core.WorkspaceLock

  setup do
    %{workspace: "lock_#{System.unique_integer([:positive])}"}
  end

  test "a killed owner releases to the next waiter", %{workspace: workspace} do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        WorkspaceLock.with_lock(workspace, fn ->
          send(parent, :owned)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :owned
    waiter = Task.async(fn -> WorkspaceLock.with_lock(workspace, fn -> :acquired end) end)
    await_queued(waiter.pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert Task.await(waiter) == :acquired
    refute WorkspaceLock.locked?(workspace)
  end

  test "a timed-out live waiter cannot inherit a lock", %{workspace: workspace} do
    :ok = WorkspaceLock.acquire(workspace)
    parent = self()

    waiter =
      Task.async(fn ->
        result = catch_exit(WorkspaceLock.acquire(workspace, 10))
        send(parent, {:timed_out, result})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:timed_out, {:timeout, _}}
    :ok = WorkspaceLock.release(workspace)
    refute WorkspaceLock.locked?(workspace)
    send(waiter.pid, :finish)
    Task.await(waiter)
    assert WorkspaceLock.with_lock(workspace, fn -> :acquired end) == :acquired
  end

  test "a dead queued waiter is skipped", %{workspace: workspace} do
    :ok = WorkspaceLock.acquire(workspace)
    {waiter, monitor} = spawn_monitor(fn -> WorkspaceLock.acquire(workspace) end)
    await_queued(waiter)
    Process.exit(waiter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^waiter, :killed}
    :ok = WorkspaceLock.release(workspace)
    assert WorkspaceLock.with_lock(workspace, fn -> :acquired end) == :acquired
  end

  test "another process cannot release the owner", %{workspace: workspace} do
    :ok = WorkspaceLock.acquire(workspace)
    task = Task.async(fn -> WorkspaceLock.release(workspace) end)
    assert Task.await(task) == {:error, :not_owner}
    assert WorkspaceLock.locked?(workspace)
    :ok = WorkspaceLock.release(workspace)
  end

  test "waiters acquire in order", %{workspace: workspace} do
    :ok = WorkspaceLock.acquire(workspace)
    parent = self()

    waiters =
      for index <- 1..3 do
        task =
          Task.async(fn ->
            WorkspaceLock.with_lock(workspace, fn ->
              send(parent, {:acquired, index})

              receive do
                :release -> :ok
              end
            end)
          end)

        await_queued(task.pid)
        task
      end

    :ok = WorkspaceLock.release(workspace)

    for {task, index} <- Enum.with_index(waiters, 1) do
      assert_receive {:acquired, ^index}
      refute_receive {:acquired, _}, 0
      send(task.pid, :release)
      Task.await(task)
    end

    refute WorkspaceLock.locked?(workspace)
  end

  test "exceptions release the lock", %{workspace: workspace} do
    assert_raise RuntimeError, "failed", fn ->
      WorkspaceLock.with_lock(workspace, fn -> raise "failed" end)
    end

    refute WorkspaceLock.locked?(workspace)
  end

  defp await_queued(pid, attempts \\ 100) do
    if inspect(:sys.get_state(WorkspaceLock)) =~ inspect(pid) do
      :ok
    else
      assert attempts > 0, "waiter did not enqueue"

      receive do
      after
        1 -> await_queued(pid, attempts - 1)
      end
    end
  end
end
