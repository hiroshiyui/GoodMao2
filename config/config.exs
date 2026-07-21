# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :goodmao2, :scopes,
  user: [
    default: true,
    module: Goodmao2.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Goodmao2.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :goodmao2,
  ecto_repos: [Goodmao2.Repo],
  generators: [timestamp_type: :utc_datetime]

# Internationalization. `en` is the base/reference locale; `zh_TW` and `ja_JP` are
# the shipped translations (ADR-0002). The per-request locale is resolved by
# Goodmao2Web.Plugs.Locale (cookie → Accept-Language → default).
config :goodmao2, Goodmao2Web.Gettext,
  default_locale: "en",
  locales: ~w(en zh_TW ja_JP)

# Configure the endpoint
config :goodmao2, Goodmao2Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: Goodmao2Web.ErrorHTML, json: Goodmao2Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Goodmao2.PubSub,
  live_view: [signing_salt: "Tb0GHETD"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :goodmao2, Goodmao2.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  goodmao2: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # The service worker is a separate bundle served from the site root (scope "/"), so it
  # cannot live under /assets. It has no imports; --bundle just resolves + minifies it.
  service_worker: [
    args: ~w(js/service_worker.js --bundle --target=es2022 --outdir=../priv/static),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  goodmao2: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Timezone awareness (ADR-0018). The `tz` database backs DateTime.shift_zone/2 so stored-UTC
# times render in the viewer's zone. `:default_timezone` is the last-resort fallback when no
# admin system default is set (Settings key "default_timezone") and the user has no preference.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase
config :goodmao2, :default_timezone, "Etc/UTC"

# Background jobs (Oban). Today it runs a single daily cron — the token janitor that
# prunes expired auth tokens (Accounts.delete_expired_tokens/0); more workloads
# (reminders, async media, notification fan-out) are deferred (doc/roadmap.md).
config :goodmao2, Oban,
  repo: Goodmao2.Repo,
  queues: [default: 10],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"30 3 * * *", Goodmao2.Accounts.TokenJanitor}
     ]}
  ]

# LifeLog media (ADR-0005). Uploads are purified with ffmpeg (images re-encoded, videos
# remuxed to strip EXIF/GPS/metadata) and stored as opaque objects keyed by id, served only
# through an authorized endpoint. `storage_dir` is set per-environment (a writable path
# *outside* any served directory); prod fails fast if it is unset (see runtime.exs).
config :goodmao2, Goodmao2.Media,
  max_image_bytes: 15_000_000,
  max_video_bytes: 100_000_000,
  max_video_seconds: 60,
  max_entries: 4,
  rate_limit_per_hour: 30

# Web Push (ADR-0011 Stage 2). Per-user hourly cap on subscribe/unsubscribe writes. The
# VAPID keypair itself is *not* configured here — an administrator generates it from
# `/admin/settings` and it is stored (private key encrypted) in the `settings` table.
config :goodmao2, Goodmao2.Notifications, push_subscribe_per_hour: 60

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
