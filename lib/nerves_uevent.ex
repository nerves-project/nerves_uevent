# SPDX-FileCopyrightText: 2022 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesUEvent do
  @moduledoc """
  NervesUEvent listens for events from the Linux kernel, automatically loads
  device drivers, and forwards them to your Elixir programs.

  NervesUEvent is a very simple version of the Linux `udevd`. Just like `udevd`
  does for desktop Linux, NervesUEvent registers to receive UEvents from the Linux
  kernel. Unlike `udevd`, NervesUEvent only runs `modprobe` when needed and keeps
  track of what hardware is in the system. For most Nerves use cases, `udevd`
  isn't needed.
  """

  @typedoc """
  Uevent action type counters
  """
  @type action_stats() :: %{
          add: non_neg_integer(),
          change: non_neg_integer(),
          remove: non_neg_integer(),
          move: non_neg_integer(),
          bind: non_neg_integer(),
          unbind: non_neg_integer(),
          other: non_neg_integer()
        }

  @typedoc """
  UEvent collection counters

  * `:uevents_received` — netlink messages successfully read
  * `:uevents_dropped` — ENOBUFS incidents (kernel dropped one or more messages)
  * `:modprobes_called` — modprobe child processes launched
  * `:modaliases_queued` — modaliases queued for modprobe
  * `:modaliases_dropped` — modaliases dropped because the queue was full
    while a modprobe was already in flight
  * `:modprobe_fork_failures` — `fork()` failures when launching modprobe
  * `:peak_queue_n` — high-water mark for queued modalias count
  * `:peak_queue_bytes` — high-water mark for the modalias byte buffer
  * `:actions` — nested map of `add | change | remove | move | bind | unbind | other`
    counts, matching the uevent ACTION field
  """
  @type stats() :: %{
          uevents_received: non_neg_integer(),
          uevents_dropped: non_neg_integer(),
          modprobes_called: non_neg_integer(),
          modaliases_queued: non_neg_integer(),
          modaliases_dropped: non_neg_integer(),
          modprobe_fork_failures: non_neg_integer(),
          peak_queue_n: non_neg_integer(),
          peak_queue_bytes: non_neg_integer(),
          actions: action_stats()
        }

  @doc """
  Get all reported UEvents
  """
  @spec get_all() :: [{PropertyTable.property(), PropertyTable.value()}]
  def get_all(), do: PropertyTable.get_all(NervesUEvent)

  @doc """
  Get the most recent  value of UEvent report

  For example,

  ```elixir
  > NervesUEvent.get(["devices", "platform", "leds", "leds", "red:indicator-1"])
  %{
    "of_compatible_n" => "0",
    "of_fullname" => "/leds/rgb1-blue",
    "of_name" => "rgb1-blue",
    "subsystem" => "leds"
  }}
  ```
  """
  @spec get(PropertyTable.property(), PropertyTable.value()) :: PropertyTable.value()
  def get(property, default \\ nil), do: PropertyTable.get(NervesUEvent, property, default)

  @doc """
  Run an arbitrary match against UEvents

  Use `:_` in the path to accept any value in that position
  Use `:"$"` at the end of the path to perform an exact match
  """
  @spec match(PropertyTable.pattern()) :: [{PropertyTable.property(), PropertyTable.value()}]
  def match(pattern), do: PropertyTable.match(NervesUEvent, pattern)

  @doc """
  Subscribe to uevent notifications

  Pass a pattern like one you'd pass to `match/1`. Instead of getting a
  response, you'll receive a message when a matching UEvent happens.
  """
  @spec subscribe(PropertyTable.pattern()) :: :ok
  def subscribe(property), do: PropertyTable.subscribe(NervesUEvent, property)

  @doc """
  Return counters collected by the uevent port.

  Counters are cumulative since the port started and updated after 5 seconds of
  inactivity.  Values will lag bursts especially at boot.
  """
  @spec stats() :: NervesUEvent.stats()
  def stats(), do: NervesUEvent.stats()
end
