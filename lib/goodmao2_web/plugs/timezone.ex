defmodule Goodmao2Web.Plugs.Timezone do
  @moduledoc """
  Resolves the active timezone for a (dead-view) request and applies it (ADR-0018):

    * stashes it in the process dictionary (`Goodmao2.Timezone.put_current/1`) so the view
      helpers (`format_datetime/1` / `format_date/1`) shift stored-UTC times without every
      call site threading a zone,
    * assigns `@timezone` for templates/controllers that want it explicitly.

  Resolution is `user preference → system default → Etc/UTC` (`Goodmao2.Timezone.resolve/1`).
  Must run **after** `:fetch_current_scope_for_user` in the `:browser` pipeline so the logged-in
  user's preference is visible; anonymous requests fall back to the system default.
  """
  import Plug.Conn

  alias Goodmao2.Timezone

  def init(opts), do: opts

  def call(conn, _opts) do
    tz = Timezone.resolve(conn.assigns[:current_scope])
    Timezone.put_current(tz)
    assign(conn, :timezone, tz)
  end
end
