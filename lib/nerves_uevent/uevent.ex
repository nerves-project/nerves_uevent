# SPDX-FileCopyrightText: 2022 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesUEvent.UEvent do
  @moduledoc false
  use GenServer
  require Logger

  @type option() :: {:autoload_modules, boolean()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check whether uevent is even supported on this platform
  """
  @spec supported?() :: boolean()
  def supported?() do
    executable = Application.app_dir(:nerves_uevent, ["priv", "uevent"])
    File.exists?(executable)
  end

  @doc """
  Return the most recent counters reported by the C port.

  The port pushes an updated snapshot after ~5 s of netlink idle, so the
  returned map may lag real counts during a uevent burst.
  """
  @spec stats() :: NervesUEvent.stats()
  def stats(), do: GenServer.call(__MODULE__, :stats)

  @doc """
  Broadcast a synthetic udev event on NETLINK_KOBJECT_UEVENT group 2.

  Properties are KEY => VAL strings (uppercase keys, per udev convention).
  Must include at least `"ACTION"`, `"DEVPATH"`, and `"SUBSYSTEM"` for
  libudev clients to filter and dispatch the event correctly. No-op when
  the C port isn't running (e.g. on non-Linux hosts).
  """
  @spec broadcast(%{String.t() => String.t()}) :: :ok
  def broadcast(props) when is_map(props) do
    GenServer.cast(__MODULE__, {:broadcast, props})
  end

  @impl GenServer
  def init(opts) do
    autoload = Keyword.get(opts, :autoload_modules, true)
    executable = Application.app_dir(:nerves_uevent, ["priv", "uevent"])

    args = if autoload, do: ["modprobe"], else: []

    port =
      Port.open({:spawn_executable, executable}, [
        {:args, args},
        {:packet, 2},
        :use_stdio,
        :binary,
        :exit_status
      ])

    {:ok, %{port: port, stats: initial_stats()}}
  end

  defp initial_stats() do
    %{
      uevents_received: 0,
      uevents_dropped: 0,
      modprobes_called: 0,
      modaliases_queued: 0,
      modaliases_dropped: 0,
      modprobe_fork_failures: 0,
      peak_queue_n: 0,
      peak_queue_bytes: 0,
      actions: %{
        add: 0,
        change: 0,
        remove: 0,
        move: 0,
        bind: 0,
        unbind: 0,
        other: 0
      }
    }
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl GenServer
  def handle_cast({:broadcast, props}, state) do
    body =
      props
      |> Enum.flat_map(fn {k, v} -> [k, ?=, v, 0] end)
      |> IO.iodata_to_binary()

    _ = Port.command(state.port, :erlang.term_to_binary({:broadcast, body}))
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({port, {:data, message}}, %{port: port} = state) do
    new_state =
      case :erlang.binary_to_term(message) do
        {:add, path, kvmap} ->
          PropertyTable.put(NervesUEvent, path, kvmap)
          state

        {:bind, _path, _kvmap} ->
          # Ignore device driver bind updates
          state

        {:change, path, kvmap} ->
          PropertyTable.put(NervesUEvent, path, kvmap)
          state

        {:move, new_path, %{"devpath_old" => devpath_old}} ->
          old_path = String.split(devpath_old, "/")
          kvmap = PropertyTable.get(NervesUEvent, old_path)
          PropertyTable.delete(NervesUEvent, old_path)
          PropertyTable.put(NervesUEvent, new_path, kvmap)
          state

        {:remove, path, _kvmap} ->
          PropertyTable.delete(NervesUEvent, path)
          state

        {:stats, stats} when is_map(stats) ->
          %{state | stats: stats}

        {:unbind, _path, _kvmap} ->
          # Ignore device driver unbind updates
          state

        {other, path, kvmap} ->
          Logger.error(
            "Unexpected uevent reported: #{inspect(other)}, #{inspect(path)}, #{inspect(kvmap)}"
          )

          state
      end

    {:noreply, new_state}
  end

  def handle_info(_, state), do: {:noreply, state}
end
