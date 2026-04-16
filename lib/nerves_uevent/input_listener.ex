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

  defp udev_data_dir(opts) do
    Path.join(Keyword.get(opts, :udev_dir, @default_udev_dir), "data")
  end

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
        if File.exists?("/run/udev/control") do
          Logger.warning("""
          udevd appears to be running (/run/udev/control exists). NervesUEvent's \
          input-device management is disabled to avoid conflicts.

          To replace udevd with NervesUEvent:
              config :nerves_uevent, manage_udev: true

          To keep udevd and silence this warning:
              config :nerves_uevent, manage_udev: false\
          """)

          false
        else
          true
        end
    end
  end

  @impl GenServer
  def init(opts) do
    :ok = PropertyTable.subscribe(NervesUEvent, [])
    {:ok, %{udev_data_dir: udev_data_dir(opts)}, {:continue, :initial_sync}}
  end

  @impl GenServer
  def handle_continue(:initial_sync, state) do
    # Clear out any previous state
    _ = File.rm_rf(state.udev_data_dir)
    File.mkdir_p!(state.udev_data_dir)

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
    _ = write_udev_data(state.udev_data_dir, value, classes)
    Logger.info("Input device added: #{devpath(property)} #{inspect(classes)}")
  end

  defp write_udev_data(udev_data_dir, value, classes) do
    lines =
      [
        "E:ID_INPUT=1\n"
        | Enum.map(classes, &"E:ID_INPUT_#{String.upcase(Atom.to_string(&1))}=1\n")
      ]

    File.write(udev_data_file(udev_data_dir, value), lines)
  end

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
