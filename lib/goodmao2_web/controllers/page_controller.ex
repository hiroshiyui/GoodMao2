defmodule Goodmao2Web.PageController do
  use Goodmao2Web, :controller

  def home(conn, _params) do
    # Signed-in caretakers go straight to their pets; guests see the landing page.
    case conn.assigns[:current_scope] do
      %{user: %{}} -> redirect(conn, to: ~p"/pets")
      _ -> render(conn, :home)
    end
  end
end
