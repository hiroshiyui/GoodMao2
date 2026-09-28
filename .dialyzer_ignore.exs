# Dialyzer baseline. Reviewed 2026-09-28: the first run reported 38 warnings, and 6 remain.
#
#   * 25 were specs naming `User.t()` / `WebAuthnCredential.t()`, which neither schema
#     defined; both now do.
#   * Real defects fixed rather than listed: both ETS rate limiters passed their table to
#     `:ets.foldl/3` first instead of last, so every sweep raised and the restart wiped the
#     counters (the hourly login, second-factor and registration-email ceilings were really
#     ten-minute ones); and `PurifyWorker.reason_string/1` had a non-atom catch-all no
#     purifier result can reach, deleted per AGENTS.md ("a catch-all clause no caller can
#     reach").
#   * What is left cannot be fixed in this code. Each is an opaque-type notice about a
#     library's own value: an `Ecto.Multi` built by `Ecto.Multi.new/0` carries a `MapSet`
#     (whose `:sets.set` is opaque) and Dialyzer rejects handing it back to `Ecto.Multi`
#     itself; Gettext's generated `plural/2` does the same with its plural-forms struct.
#
# Entries are by file and kind, never by line, so an unrelated edit does not fail CI. CI
# fails on any warning not covered here, and `list_unused_filters` reports an entry whose
# warnings are gone: remove it then. Never add one without reading the warning first, and
# prefer fixing the code — a checker's proof that a clause is unreachable means delete it.
[
  {"lib/goodmao2/logs.ex", :call_without_opaque},
  {"lib/goodmao2/media.ex", :call_without_opaque},
  {"lib/goodmao2/media/avatars.ex", :call_without_opaque},
  {"lib/goodmao2_web/gettext.ex", :call_without_opaque}
]
