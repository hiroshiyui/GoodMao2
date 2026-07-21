defmodule Goodmao2Web do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and so on.

  This can be used in your application as:

      use Goodmao2Web, :controller
      use Goodmao2Web, :html

  The definitions below will be executed for every controller,
  component, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define additional modules and import
  those modules here.
  """

  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt service_worker.js)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      # Import common connection and controller functions to use in pipelines
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      use Gettext, backend: Goodmao2Web.Gettext

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      # Include general helpers for rendering HTML
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Translation
      use Gettext, backend: Goodmao2Web.Gettext

      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import Goodmao2Web.CoreComponents
      # Per-type log entry input fields (shared by QuickLog and the entry editor)
      import Goodmao2Web.LogFields
      # Life-log media rendering (shared by the timeline and the entry page)
      import Goodmao2Web.MediaComponents
      # Health-summary report rendering + the shared weight-trend chart
      import Goodmao2Web.ReportComponents
      # App-wide view helpers (label translations, log summaries, formatting)
      import Goodmao2Web.Helpers

      # Common modules used in templates
      alias Phoenix.LiveView.JS
      alias Goodmao2Web.Layouts

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: Goodmao2Web.Endpoint,
        router: Goodmao2Web.Router,
        statics: Goodmao2Web.static_paths()
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/live_view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
