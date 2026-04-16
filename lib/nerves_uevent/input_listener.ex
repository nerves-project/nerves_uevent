# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesUEvent.InputListener do
  @moduledoc false
  use GenServer
  require Logger

  alias NervesUEvent.InputId

  @udev_dir "/run/udev"
  @udev_data_dir @udev_dir <> "/data"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    case manage_udev_mode(opts) do
      :enabled ->
        :ok = PropertyTable.subscribe(NervesUEvent, [])
        {:ok, %{}, {:continue, :initial_sync}}

      :disabled ->
        :ignore
    end
  end

  # Determines whether to manage /run/udev. When `:manage_udev` is not set
  # and udevd is already running, NervesUEvent stays out of the way and warns
  # so the user can choose. Explicit `true`/`false` skip the detection.
  defp manage_udev_mode(opts) do
    case Keyword.get(opts, :manage_udev) do
      true ->
        :enabled

      false ->
        :disabled

      nil ->
        if File.exists?("/run/udev/control") do
          Logger.warning("""
          udevd appears to be running (/run/udev/control exists). NervesUEvent's \
          input-device management is disabled to avoid conflicts.

          To replace udevd with NervesUEvent:
              config :nerves_uevent, manage_udev: true

          To keep udevd and silence this warning:
              config :nerves_uevent, manage_udev: false\
          """)

          :disabled
        else
          :enabled
        end
    end
  end

  @impl GenServer
  def handle_continue(:initial_sync, state) do
    _ = File.rm_rf(@udev_dir)
    _ = File.mkdir_p(@udev_data_dir)

    # Replay char-device input nodes already in the table. Handles a listener
    # restart after UEvent has populated the table. Any events queued between
    # subscribe and here get processed as adds by handle_info — writing the
    # same udev file twice is idempotent.
    for {property, value} <- PropertyTable.get_all(NervesUEvent),
        input_char_device?(value) do
      add_device(property, value)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(%PropertyTable.Event{} = event, state) do
    cond do
      input_char_device?(event.value) and is_nil(event.previous_value) ->
        add_device(event.property, event.value)

      input_char_device?(event.previous_value) and is_nil(event.value) ->
        _ = File.rm(udev_data_file(event.previous_value))
        Logger.info("Input device removed: #{devpath(event.property)}")

      true ->
        :ok
    end

    {:noreply, state}
  end

  defp add_device(property, value) do
    # Capability bitmaps are in the inputN uevent kvmap, one level up in
    # PropertyTable from the eventN char device. Kernel uevent ordering
    # puts inputN before its children, so the parent is always populated
    # by the time we process the child.
    input_kvmap = PropertyTable.get(NervesUEvent, Enum.drop(property, -1), %{})
    classes = InputId.classify(input_kvmap)
    write_udev_data(value, classes)
    Logger.info("Input device added: #{devpath(property)} #{inspect(classes)}")
  end

  defp write_udev_data(value, classes) do
    lines =
      ["E:ID_INPUT=1" | Enum.map(classes, &"E:ID_INPUT_#{String.upcase(Atom.to_string(&1))}=1")]

    File.write(udev_data_file(value), Enum.join(lines, "\n") <> "\n")
  end

  # MAJOR/MINOR are only present for the char-device children of inputN
  # (event*, js*, mouse*). The logical inputN node has no dev file and
  # is filtered out here.
  defp input_char_device?(%{"subsystem" => "input", "major" => _}), do: true
  defp input_char_device?(_), do: false

  defp devpath(property), do: "/" <> Enum.join(property, "/")

  defp udev_data_file(%{"major" => major, "minor" => minor}) do
    Path.join(@udev_data_dir, "c#{major}:#{minor}")
  end
end
