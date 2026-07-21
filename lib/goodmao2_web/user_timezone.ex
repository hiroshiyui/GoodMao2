defmodule Goodmao2Web.UserTimezone do
  @moduledoc """
  LiveView `on_mount` hook that establishes the active timezone for the LiveView process
  (ADR-0018), mirroring `Goodmao2Web.UserLocale`.

  Resolves `user preference → system default → Etc/UTC` from `socket.assigns.current_scope`
  (so it must be listed **after** the scope-mounting hook), stashes it in the process dictionary
  for the view helpers, and assigns `@timezone` for templates and event handlers (e.g. parsing a
  submitted wall-clock time back to UTC). Runs on both the dead render and the connected mount.
  """
  import Phoenix.Component, only: [assign: 3]

  alias Goodmao2.Timezone

  def on_mount(:put_timezone, _params, _session, socket) do
    tz = Timezone.resolve(socket.assigns[:current_scope])
    Timezone.put_current(tz)
    {:cont, assign(socket, :timezone, tz)}
  end
end
