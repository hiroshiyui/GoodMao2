defmodule Goodmao2Web.PageController do
  use Goodmao2Web, :controller

  def home(conn, _params) do
    # Signed-in caretakers go straight to their pets; guests see the landing page.
    case conn.assigns[:current_scope] do
      %{user: %{}} ->
        redirect(conn, to: ~p"/pets")

      _ ->
        # An explicit landing title; without it the shared suffix would render the
        # brand twice ("GoodMao · GoodMao").
        conn
        |> assign(:page_title, gettext("Health timeline for the pets you love"))
        |> render(:home)
    end
  end
end
