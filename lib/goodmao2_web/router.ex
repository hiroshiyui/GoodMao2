defmodule Goodmao2Web.Router do
  use Goodmao2Web, :router

  import Goodmao2Web.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug Goodmao2Web.Plugs.Locale
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

  # Authenticated byte serving for purified media (ADR-0005): a session + current scope, but
  # no HTML content negotiation, layout, or CSRF — the controller sets its own hardened,
  # locked-down response headers.
  pipeline :serve_media do
    plug :fetch_session
    plug :fetch_flash
    # The route is GET-only, but keep CSRF protection in the stack anyway (it is a no-op for
    # safe methods) so no future unsafe verb can be added here unguarded.
    plug :protect_from_forgery
    plug :fetch_current_scope_for_user
  end

  scope "/", Goodmao2Web do
    pipe_through :browser

    get "/", PageController, :home
    get "/locale/:locale", LocaleController, :update

    # Anonymous, tokenized health-summary report — readable by anyone holding an unexpired
    # share link (no account). Existence-hidden on a bad/expired/revoked token (404).
    get "/reports/shared/:token", ReportController, :show
  end

  # Unauthenticated liveness/readiness probe (no pipeline: no session, CSRF, or
  # content negotiation to get in a monitor's way).
  scope "/", Goodmao2Web do
    get "/health", HealthController, :index
  end

  # Purified life-log media, served only to callers authorized to read the parent entry.
  scope "/", Goodmao2Web do
    pipe_through [:serve_media, :require_authenticated_user]

    get "/media/:id", MediaController, :show
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
      on_mount: [
        {Goodmao2Web.UserAuth, :require_authenticated},
        {Goodmao2Web.UserLocale, :put_locale},
        {Goodmao2Web.UnreadBadges, :mount_badges}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/password", UserLive.PasswordSettings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/users/vet-profile", UserLive.VetProfile, :edit

      # Admin-only site overview; gated per-LiveView by the :require_admin on_mount
      # (IDOR-hidden — non-admins are redirected home).
      live "/admin", AdminLive, :index

      live "/pets", PetLive.Index, :index
      # A quiet, memorial surface for pets whose care has ended — reached by a subtle
      # link from settings, deliberately kept off the active list (ADR-0003).
      live "/pets/past", PetLive.Index, :past
      live "/pets/new", PetLive.Form, :new
      live "/pets/:id", PetLive.Show, :show
      live "/pets/:id/edit", PetLive.Form, :edit
      live "/pets/:id/access", PetLive.Access, :index
      live "/pets/:id/end-of-care", PetLive.EndOfCare, :edit
      live "/pets/:id/reports", PetLive.Reports, :index
      live "/pets/:id/reports/:report_id", PetLive.Reports, :show
      live "/pets/:pet_id/logs/:id", PetLive.LogEntry, :show

      # In-site notifications (bell) and the private 1:1 mailbox (ADR-0011).
      live "/notifications", NotificationLive.Index, :index
      live "/messages", MessageLive.Index, :index
      live "/messages/:id", MessageLive.Show, :show

      # Admin-only announcement compose; gated per-LiveView by the :require_admin on_mount.
      live "/admin/announcements", AdminLive.Announcements, :new

      # Admin-only system settings (Web Push VAPID keys); gated by the :require_admin on_mount.
      live "/admin/settings", AdminLive.Settings, :index
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  # Web Push subscription API (ADR-0011 Stage 2). Through `:browser` (not `:api`) so it gets
  # session auth + CSRF; the client sends the `x-csrf-token` header.
  scope "/api", Goodmao2Web do
    pipe_through [:browser, :require_authenticated_user]

    post "/push-subscriptions", PushSubscriptionController, :create
    delete "/push-subscriptions", PushSubscriptionController, :delete
  end

  scope "/", Goodmao2Web do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        {Goodmao2Web.UserAuth, :mount_current_scope},
        {Goodmao2Web.UserLocale, :put_locale}
      ] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
