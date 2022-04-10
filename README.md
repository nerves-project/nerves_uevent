# NervesUEvent

[![CircleCI](https://circleci.com/gh/nerves-project/nerves_uevent/tree/main.svg?style=svg)](https://circleci.com/gh/nerves-project/nerves_uevent/tree/main)
[![Hex version](https://img.shields.io/hexpm/v/nerves_uevent.svg "Hex version")](https://hex.pm/packages/nerves_uevent)

NervesUEvent listens for events from the Linux kernel, automatically loads
device drivers, and forwards them to your Elixir programs.

NervesUEvent is a very simple version of the Linux `udevd`. Just like `udevd`
does for desktop Linux, NervesUEvent registers to receive UEvents from the Linux
kernel. Unlike `udevd`, NervesUEvent only runs `modprobe` when needed and keeps
track of what hardware is in the system. For most Nerves use cases, `udevd`
isn't needed.

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
application config. The following option is available:

* `:autoload_modules` - defaults to `true` to automatically run `modprobe` when
  needed

Here's a `config.exs` example:

```elixir
config :nerves_uevent, autoload_modules: false
```

## Usage


## License

Copyright (C) 2017-22 Nerves Project Authors

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at [http://www.apache.org/licenses/LICENSE-2.0](http://www.apache.org/licenses/LICENSE-2.0)

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
