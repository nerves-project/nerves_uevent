# SPDX-FileCopyrightText: 2022 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0

defmodule NervesUEvent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = Application.get_all_env(:nerves_uevent)

    uevent_supported? = NervesUEvent.UEvent.supported?()
    input_listener_supported? = uevent_supported? and NervesUEvent.InputListener.supported?(opts)

    children =
      [{PropertyTable, name: NervesUEvent}]
      |> maybe_add_child({NervesUEvent.UEvent, opts}, uevent_supported?)
      |> maybe_add_child({NervesUEvent.InputListener, opts}, input_listener_supported?)

    # :rest_for_one to handle the rare case where the PropertyTable
    # crashes. Restarting UEvent will scan the system.
    opts = [strategy: :rest_for_one, name: NervesUEvent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_child(children, child, true), do: children ++ [child]
  defp maybe_add_child(children, _child, false), do: children
end
