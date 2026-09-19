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
Ecto.Adapters.SQL.Sandbox.mode(Goodmao2.Repo, :manual)

if :feature in (ExUnit.configuration()[:include] || []) do
  Goodmao2Web.SeleniumServer.ensure_running()
end
