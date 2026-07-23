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
    # Phoenix's defaults cover referrer-policy, nosniff and x-permitted-cross-domain-policies
    # but send no X-Frame-Options, leaning on the CSP `frame-ancestors` below. Keep the
    # legacy header too -- it is the app, not the proxy, that owns its own response headers,
    # so nothing is sent twice.
    plug :put_secure_browser_headers, %{"x-frame-options" => "DENY"}
    plug Goodmao2Web.Plugs.ContentSecurityPolicy
    plug :fetch_current_scope_for_user
    plug Goodmao2Web.Plugs.Timezone
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

    # Anonymous, tokenized single log entry — the sole anonymous read path for a `public`
    # entry (ADR-0004). Existence-hidden on a bad/narrowed/expired/history-hidden token.
    get "/entries/shared/:token", SharedEntryController, :show
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

    # Profile images (ADR-0020), resolved by owner id. A user avatar is visible to any
    # authenticated user; a pet avatar re-applies that pet's read authorization (IDOR-hidden).
    get "/avatars/user/:id", AvatarController, :user
    get "/avatars/pet/:id", AvatarController, :pet
  end

  # Purified media for a `public` entry, served anonymously via its parent entry's share token
  # (ADR-0004). No auth — the token (re-checked per request against the still-shareable entry)
  # is the only gate; an unrelated media id or a dead token is existence-hidden (404).
  scope "/", Goodmao2Web do
    pipe_through :serve_media

    get "/entries/shared/:token/media/:id", MediaController, :shared
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
        {Goodmao2Web.UserTimezone, :put_timezone},
        {Goodmao2Web.UnreadBadges, :mount_badges}
      ] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/password", UserLive.PasswordSettings, :edit
      live "/users/settings/two-factor", UserLive.TwoFactorSettings, :edit
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
      live "/pets/:pet_id/medications", PetLive.Medications, :index

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

  # Second-factor challenge and forced setup (ADR-0013). The user has passed primary auth
  # but holds NO session token yet, so these are gated by `:require_pending_2fa` — not
  # `:require_authenticated`. The completion POSTs run through `:browser` for CSRF + session
  # and re-verify the pending state authoritatively in the controller.
  scope "/", Goodmao2Web do
    pipe_through [:browser]

    live_session :two_factor,
      on_mount: [
        {Goodmao2Web.UserAuth, :mount_current_scope},
        {Goodmao2Web.UserAuth, :require_pending_2fa},
        {Goodmao2Web.UserLocale, :put_locale},
        {Goodmao2Web.UserTimezone, :put_timezone}
      ] do
      live "/users/two-factor", UserLive.TwoFactor, :new
      live "/users/two-factor/setup", UserLive.TwoFactorSetup, :new
      live "/users/two-factor/recovery", UserLive.TwoFactorRecovery, :new
    end

    post "/users/two-factor/totp", UserTwoFactorController, :totp
    post "/users/two-factor/recovery", UserTwoFactorController, :recovery
    post "/users/two-factor/webauthn", UserTwoFactorController, :webauthn
    post "/users/two-factor/complete", UserTwoFactorController, :complete
  end

  scope "/", Goodmao2Web do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        {Goodmao2Web.UserAuth, :mount_current_scope},
        {Goodmao2Web.UserLocale, :put_locale},
        {Goodmao2Web.UserTimezone, :put_timezone}
      ] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
