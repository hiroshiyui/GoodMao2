import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :goodmao2, Goodmao2.Repo,
  username: "goodmao2",
  password: "goodmao2",
  hostname: "localhost",
  database: "goodmao2_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :goodmao2, Goodmao2Web.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "dti3ODpwDTQdA4KBZ4q6O+UK2ejVe9622a0zvYz2liA4NSQBqRQcMkSkvASoV/0Z",
  server: false

# In test we don't send emails
config :goodmao2, Goodmao2.Mailer, adapter: Swoosh.Adapters.Test

# In test, Oban neither runs queues nor fires cron — jobs are exercised with
# Oban.Testing (perform_job/2) for deterministic, sandbox-friendly tests.
config :goodmao2, Oban, testing: :manual

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Isolated media dir for tests; a permissive rate limit so the upload flow never trips it
# (the limiter's own logic is unit-tested directly).
config :goodmao2, Goodmao2.Media,
  storage_dir: Path.expand("../tmp/media_test", __DIR__),
  rate_limit_per_hour: 1_000_000

# Read settings straight from the DB in tests — a global ETS cache shared across the async
# sandbox would leak one test's writes into another.
config :goodmao2, Goodmao2.Settings, cache: false

# Web Push outbound client: bypass DNS/SSRF resolution and route Req through Req.Test stubs
# so delivery can be asserted inside the Ecto sandbox without real network calls.
config :goodmao2, Goodmao2.Notifications.WebPush.SafeClient,
  bypass_ssrf_check: true,
  allow_http_localhost: true,
  req_test_options: [plug: {Req.Test, Goodmao2.Notifications.WebPush.SafeClient}]

# WebAuthn/FIDO2 relying party for tests (ADR-0013). Matches the origin baked into the
# wax_ test vectors / ceremony fixtures.
config :wax_,
  origin: "https://localhost:4001",
  rp_id: "localhost"
