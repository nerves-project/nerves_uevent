defmodule NervesUEvent.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    opts = Application.get_all_env(:nerves_uevent)

    children = [
      {PropertyTable, name: NervesUEvent},
      {NervesUEvent.UEvent, opts}
    ]

    opts = [strategy: :one_for_one, name: NervesUEvent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
