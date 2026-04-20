<!--
  SPDX-FileCopyrightText: None
  SPDX-License-Identifier: CC0-1.0
-->

# Changelog

## v0.1.4 - 2026-04-20

* New feature
  * Support `libinput` by managing the `/run/udev` directory for input devices.
    This means that `eudev` or the like are no longer required for web kiosks,
    Flutter or other UI frameworks that use `libinput`.
  * Add `NervesUEvent.stats/0` for getting uevent report counters and more.

* Bug fixes
  * Fix possible dropped uevents due to `modprobe` delaying processing too much.
    `modprobe` is now called asynchrnously and modalias strings are queued for
    batch processing when it completes.

## v0.1.3 - 2026-04-10

* Updates
  * Fix issue with dropped uevents during initial device enumeration. This
    resulted in a device driver not being modprobed. The fix is to significantly
    increase the max queue length, which mirrors how other tools solved the
    issue.
  * Reduce calls to modprobe by pruning modalias duplicates

## v0.1.2 - 2025-06-17

* Updates
  * Improve C compilation error message to help custom Nerves systems builders
  * Fix Elixir 1.19 warning

## v0.1.1 - 2025-01-06

* Updates
  * Allow `property_table` v0.3.x to be used
  * Add REUSE compliance
  * Test with latest libraries and Elixir 1.18. This release also removes
    official support for Elixir 1.9-1.12. Nothing is known to break those
    versions, but they also aren't regularly tested.

## v0.1.0 - 2022-04-26

Extract UEvent code from
[Nerves.Runtime](https://hex.pm/packages/nerves_runtime) and update to use the
[PropertyTable](https://hex.pm/packages/property_table) library.

