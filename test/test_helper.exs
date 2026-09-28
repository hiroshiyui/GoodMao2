# Wallaby drives a real Firefox for the feature tests; starting it here is harmless when they
# are excluded, which they are by default.
{:ok, _} = Application.ensure_all_started(:wallaby)

# Wallaby 0.30 still speaks the legacy JSON Wire Protocol in places Selenium 4 rejects: it
# sends "" rather than "{}" as the body of a param-less POST (element/clear, element/click),
# and set_value in the pre-W3C shape. This replaces Wallaby.HTTPClient with a corrected copy.
# Compiled at runtime so the deliberate redefinition is not a compile-time warning.
Code.put_compiler_option(:ignore_module_conflict, true)
Code.compile_file("test/support/wallaby_httpclient_patch.exs")
Code.put_compiler_option(:ignore_module_conflict, false)

# Feature tests need a browser and a Selenium server, so they are opt-in: `mix test.feature`,
# or `mix test --include feature`.
ExUnit.start(exclude: [:feature])

# Commit the one administrator before the sandbox takes over. `users_single_admin_index` is a
# partial unique index on `is_admin`, so every admin row has the same key: while each async
# test inserted its own admin inside its sandbox transaction, PostgreSQL made the next one wait
# for that whole test to end (Baudrate 15bec4d4). Against a committed admin, `admin_fixture/1`
# only reads. So the users table is never empty in a test; the few that need it empty (the
# first-registered-user-becomes-admin rule) call `remove_all_users/0` from an async: false
# module.
Goodmao2.AccountsFixtures.seed_committed_admin()

Ecto.Adapters.SQL.Sandbox.mode(Goodmao2.Repo, :manual)

if :feature in (ExUnit.configuration()[:include] || []) do
  Goodmao2Web.SeleniumServer.ensure_running()
end
