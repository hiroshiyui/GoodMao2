defmodule Goodmao2Web.SharedEntryController do
  @moduledoc """
  Serves a single `public` log entry to an anonymous holder of its share link (ADR-0004).

  The only gate is the token: `Logs.fetch_entry_by_share_token/1` returns the entry only when it
  is still public, unexpired, non-deleted, and the pet's history is not hidden. A bad, narrowed,
  expired, or history-hidden token is reported as `not_found` — existence-hidden, like the report
  and media endpoints. The grant-gated timeline never serves anonymous callers.
  """
  use Goodmao2Web, :controller

  alias Goodmao2.Logs

  def show(conn, %{"token" => token}) do
    case Logs.fetch_entry_by_share_token(token) do
      nil ->
        conn |> put_status(:not_found) |> put_view(Goodmao2Web.ErrorHTML) |> render(:"404")

      entry ->
        conn
        |> assign(:page_title, gettext("Shared entry"))
        |> assign(:entry, entry)
        |> assign(:token, token)
        |> render(:show)
    end
  end
end
