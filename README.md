<!--
  SPDX-FileCopyrightText: 2022 Frank Hunleth
  SPDX-License-Identifier: CC-BY-4.0
-->

# NervesUEvent

[![Hex version](https://img.shields.io/hexpm/v/nerves_uevent.svg "Hex version")](https://hex.pm/packages/nerves_uevent)
[![API docs](https://img.shields.io/hexpm/v/nerves_uevent.svg?label=hexdocs "API docs")](https://hexdocs.pm/nerves_uevent/NervesUEvent.html)
[![CircleCI](https://dl.circleci.com/status-badge/img/gh/nerves-project/nerves_uevent/tree/main.svg?style=svg)](https://dl.circleci.com/status-badge/redirect/gh/nerves-project/nerves_uevent/tree/main)
[![REUSE status](https://api.reuse.software/badge/github.com/nerves-project/nerves_uevent)](https://api.reuse.software/info/github.com/nerves-project/nerves_uevent)

NervesUEvent listens for events from the Linux kernel, automatically loads
device drivers, and forwards them to your Elixir programs.

NervesUEvent supports a small subset of Linux's `udevd`. This subset is
sufficient for many Nerves use cases and you can add listeners that respond
similar to what udev's rules files do. Supported features:

* Load kernel modules on demand
* Categorize input devices for programs using libinput
* Support a PropertyTable-style interface detecting device insertions and
  removals in Elixir

> #### Warning {: .warning}
>
> Almost all Nerves systems require some kernel modules to be automatically
> loaded or critical functionality won't work. WiFi device drivers, for example,
> are almost always kernel modules. If you're not using NervesUEvent or `udevd`
> or some other library that automatically loads kernel modules, you'll need to
> add calls to `modprobe` to your application.

Nerves projects generally depend on either `:nerves_uevent` or a version of
[`:nerves_runtime`](https://hex.pm/packages/nerves_runtime) that included
similar functionality. It's an advanced use case to modify this dependency.

## Configuration

NervesUEvent automatically starts on boot. Configuration is supplied via
application config. The following options are available:

* `:autoload_modules` - defaults to `true` to automatically run `modprobe` when
  needed
* `:manage_udev` - set this to `true` or `false` to force NervesUEvent to
  manage the `/run/udev` directory. If unset, NervesUEvent manages it if
  udevd isn't running. Currently, NervesUEvent only maintains input device
  status for libinput.
* `:input_rules` - a list of `{match, actions}` tuples applied to each input
  device. `match` is a map of `field => value` pairs with string keys,
  compared as a subset against the inputN uevent (e.g. `"name"`, `"phys"`,
  `"uniq"`) — every key in `match` must equal the kvmap's value. `actions`
  is a keyword list of actions to apply on match. Currently the only
  supported action is `:env`, a map of property name to value that gets
  appended as `E:KEY=VALUE` lines in `/run/udev/data/c<major>:<minor>`.
  Multiple matching rules merge their env; later rules win on conflicting
  keys.

Here's a `config.exs` example:

```elixir
# Rotate a touchscreen by setting libinput's calibration matrix. Matrix
# values: 0° = "1 0 0 0 1 0", 90° CW = "0 -1 1 1 0 0",
# 180° = "-1 0 1 0 -1 1", 270° CW = "0 1 0 -1 0 1"
config :nerves_uevent,
  input_rules: [
    {%{"name" => "TSTP MTouch"},
     env: %{"LIBINPUT_CALIBRATION_MATRIX" => "0 1 0 -1 0 1"}}
  ]
```

## Usage

NervesUEvent is currently very low level in what it reports and reflects the
Linux representation. For example, say that you're interested in an MMC device
and you've found out that Linux exposes it in the
`/sys/devices/platform/soc/2100000.bus/2194000.mmc` directory. Linux also sends
UEvent messages for all devices in `/sys/device`, so NervesUEvent will know
about this too. To query NervesUEvent for device information, drop `/sys` off
the path and convert to a list of strings like this:

```elixir
iex> NervesUEvent.get(["devices", "platform", "soc", "2100000.bus", "2190000.mmc"])
%{
  "driver" => "sdhci-esdhc-imx",
  "modalias" => "of:NmmcT(null)Cfsl,imx6ull-usdhcCfsl,imx6sx-usdhc",
  "of_alias_0" => "mmc1",
  "of_compatible_0" => "fsl,imx6ull-usdhc",
  "of_compatible_1" => "fsl,imx6sx-usdhc",
  "of_compatible_n" => "2",
  "of_fullname" => "/soc/bus@2100000/mmc@2190000",
  "of_name" => "mmc",
  "subsystem" => "platform"
}
```

Some devices have more useful information than others. This particular one
mostly shows information found in the device tree file for this device. Of note
is the `"modalias"` key. When NervesUEvent sees this, it will try to load the
appropriate Linux kernel driver for this device if one exists.

More usefully, you can subscribe for events. For example, if you'd like to be
notified when a MicroSD card has been inserted, you can subscribe to all events
on that device:

```elixir
iex> NervesUEvent.subscribe(["devices", "platform", "soc", "2100000.bus", "2190000.mmc"])
```

If you're not sure what to subscribe to, subscribe to all events to see what happens:

```elixir
iex> NervesUEvent.subscribe([])
```

Now if you physically insert a MicroSD card, NervesUEvent will send messages to
your process mailbox. Here's one of the events:

```elixir
iex> flush
%PropertyTable.Event{
  table: NervesUEvent,
  timestamp: 2558213871126,
  property: ["devices", "platform", "soc", "2100000.bus", "2190000.mmc", "mmc_host", "mmc0", "mmc0:1234"],
  value: %{
    "mmc_name" => "SA04G",
    "mmc_type" => "SD",
    "modalias" => "mmc:block",
    "subsystem" => "mmc"
  },
  previous_timestamp: nil,
  previous_value: nil
}
```

The primary fields of interest are `:table`, `:timestamp`, `:property`, and
`:value`. NervesUEvent uses the PropertyTable library for storing everything and
publishing changes. The timestamps are from `System.monotonic_time/0`.

## License

All original source code in this project is licensed under Apache-2.0.

Additionally, this project follows the [REUSE recommendations](https://reuse.software)
and labels so that licensing and copyright are clear at the file level.

Exceptions to Apache-2.0 licensing are:

* Configuration and data files are licensed under CC0-1.0
* Documentation is CC-BY-4.0
