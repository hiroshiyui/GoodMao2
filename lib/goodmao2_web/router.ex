defmodule Goodmao2Web.Router do
  use Goodmao2Web, :router

  import Goodmao2Web.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Goodmao2Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug Goodmao2Web.Plugs.ContentSecurityPolicy
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", Goodmao2Web do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Unauthenticated liveness/readiness probe (no pipeline: no session, CSRF, or
  # content negotiation to get in a monitor's way).
  scope "/", Goodmao2Web do
    get "/health", HealthController, :index
  end

  # Other scopes may use custom stacks.
  # scope "/api", Goodmao2Web do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:goodmao2, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: Goodmao2Web.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", Goodmao2Web do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{Goodmao2Web.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/password", UserLive.PasswordSettings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email

      live "/pets", PetLive.Index, :index
      live "/pets/new", PetLive.Form, :new
      live "/pets/:id", PetLive.Show, :show
      live "/pets/:id/edit", PetLive.Form, :edit
      live "/pets/:id/access", PetLive.Access, :index
      live "/pets/:id/end-of-care", PetLive.EndOfCare, :edit
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", Goodmao2Web do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{Goodmao2Web.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
