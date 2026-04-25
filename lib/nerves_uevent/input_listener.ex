# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesUEvent.InputListener do
  @moduledoc false
  use GenServer

  alias NervesUEvent.InputId
  require Logger

  @default_udev_dir "/run/udev"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec supported?(keyword()) :: boolean()
  def supported?(opts) do
    manage_run_udev?(opts) and writable_dir?(udev_data_dir(opts))
  end

  defp udev_dir(opts), do: Keyword.get(opts, :udev_dir, @default_udev_dir)
  defp udev_data_dir(opts), do: Path.join(udev_dir(opts), "data")
  defp udev_control_path(opts), do: Path.join(udev_dir(opts), "control")

  defp writable_dir?(path) do
    case File.stat(path) do
      {:ok, %{type: :directory, access: :read_write}} -> true
      {:error, :enoent} -> File.mkdir_p(path) == :ok
      _ -> false
    end
  end

  defp manage_run_udev?(opts) do
    case Keyword.fetch(opts, :manage_udev) do
      {:ok, value} ->
        value

      :error ->
        # systemd-udevd creates /run/udev/control as a Unix socket; libudev
        # treats that file's existence as the signal that "a udev instance is
        # running" and only then subscribes to NETLINK_KOBJECT_UEVENT group 2.
        # We advertise ourselves the same way (see handle_continue/2), but
        # using a regular file so we can tell our marker apart from a real
        # udevd's socket on a warm BEAM restart.
        case File.lstat(udev_control_path(opts)) do
          {:ok, %{type: :other}} ->
            Logger.warning("""
            udevd appears to be running (/run/udev/control is a socket). \
            NervesUEvent's input-device management is disabled to avoid conflicts.

            To replace udevd with NervesUEvent:
                config :nerves_uevent, manage_udev: true

            To keep udevd and silence this warning:
                config :nerves_uevent, manage_udev: false\
            """)

            false

          _ ->
            true
        end
    end
  end

  @impl GenServer
  def init(opts) do
    :ok = PropertyTable.subscribe(NervesUEvent, [])

    state = %{
      udev_data_dir: udev_data_dir(opts),
      udev_control_path: udev_control_path(opts),
      input_rules: Keyword.get(opts, :input_rules, [])
    }

    {:ok, state, {:continue, :initial_sync}}
  end

  @impl GenServer
  def handle_continue(:initial_sync, state) do
    # Clear out any previous state
    _ = File.rm_rf(state.udev_data_dir)
    File.mkdir_p!(state.udev_data_dir)

    # Advertise as a running udev instance so libudev clients (libinput,
    # udevadm) actually subscribe to NETLINK_KOBJECT_UEVENT group 2. Without
    # this, sd_device_monitor_new sets group=NONE and never receives our
    # broadcasts. F_OK is all libudev checks — a regular file suffices.
    _ = File.touch(state.udev_control_path)

    # Replay char-device input nodes already in the table. Handles a listener
    # restart after UEvent has populated the table. Any events queued between
    # subscribe and here get processed as adds by handle_info — writing the
    # same udev file twice is idempotent.
    for {property, value} <- PropertyTable.get_all(NervesUEvent),
        input_char_device?(value) do
      add_device(property, value, state)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(%PropertyTable.Event{previous_value: nil} = event, state) do
    if input_char_device?(event.value) do
      add_device(event.property, event.value, state)
    end

    {:noreply, state}
  end

  def handle_info(%PropertyTable.Event{value: nil} = event, state) do
    if input_char_device?(event.previous_value) do
      _ = File.rm(udev_data_file(state.udev_data_dir, event.previous_value))
      remove_device(event.property, event.previous_value)
      Logger.info("Input device removed: #{devpath(event.property)}")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp add_device(property, value, state) do
    # Capability bitmaps are in the inputN uevent kvmap, one level up in
    # PropertyTable from the eventN char device. Kernel uevent ordering
    # puts inputN before its children, so the parent is always populated
    # by the time we process the child.
    input_kvmap = PropertyTable.get(NervesUEvent, Enum.drop(property, -1), %{})
    classes = InputId.classify(input_kvmap)
    extra_env = rule_env(state.input_rules, input_kvmap)
    _ = write_udev_data(state.udev_data_dir, value, classes, extra_env)

    # Libinput's quirks DB also keys on NAME/PHYS/UNIQ/PRODUCT, which live
    # on the parent inputN, not the eventN node — pull those forward.
    parent = Map.take(input_kvmap, ["name", "phys", "uniq", "product"])

    classifications = Map.new(classes, fn c -> {classification_key(c), "1"} end)

    extras = Map.new(extra_env, fn {k, v} -> {to_string(k), to_string(v)} end)

    props =
      base_props("add", property)
      |> Map.merge(upcase_keys(parent))
      |> Map.merge(upcase_keys(value))
      |> Map.put("ID_INPUT", "1")
      |> Map.merge(classifications)
      |> Map.merge(extras)

    NervesUEvent.UEvent.broadcast(props)
    Logger.info("Input device added: #{devpath(property)} #{inspect(classes)}")
  end

  defp remove_device(property, previous_value) do
    props =
      base_props("remove", property)
      |> Map.merge(upcase_keys(previous_value))

    NervesUEvent.UEvent.broadcast(props)
  end

  defp base_props(action, property) do
    %{
      "ACTION" => action,
      "DEVPATH" => devpath(property),
      "SUBSYSTEM" => "input"
    }
  end

  defp upcase_keys(map), do: Map.new(map, fn {k, v} -> {String.upcase(k), v} end)

  defp rule_env(rules, kvmap) do
    Enum.reduce(rules, %{}, fn {match, actions}, acc ->
      if rule_matches?(match, kvmap) do
        Map.merge(acc, Keyword.get(actions, :env, %{}))
      else
        acc
      end
    end)
  end

  # Subset match: every key in `match` must equal the corresponding value in
  # `kvmap`. Extra keys in `kvmap` are ignored — same semantics as
  # `match?(%{...literal pairs...}, kvmap)`.
  defp rule_matches?(match, kvmap) do
    Enum.all?(match, fn {k, v} -> Map.get(kvmap, k) == v end)
  end

  defp write_udev_data(udev_data_dir, value, classes, extra_env) do
    lines =
      ["E:ID_INPUT=1\n"] ++
        Enum.map(classes, &"E:#{classification_key(&1)}=1\n") ++
        Enum.map(extra_env, fn {k, v} -> "E:#{k}=#{v}\n" end)

    File.write(udev_data_file(udev_data_dir, value), lines)
  end

  defp classification_key(class), do: "ID_INPUT_#{class |> Atom.to_string() |> String.upcase()}"

  # MAJOR/MINOR are only present for the char-device children of inputN
  # (event*, js*, mouse*). The logical inputN node has no dev file and
  # is filtered out here.
  defp input_char_device?(%{"subsystem" => "input", "major" => _}), do: true
  defp input_char_device?(_), do: false

  defp devpath(property), do: "/" <> Enum.join(property, "/")

  defp udev_data_file(udev_data_dir, %{"major" => major, "minor" => minor}) do
    Path.join(udev_data_dir, "c#{major}:#{minor}")
  end
end
