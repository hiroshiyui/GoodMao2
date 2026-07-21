# 18. Timezone-aware display and input

- **Status:** Accepted _(shipped)_
- **Date:** 2026-07-21
- **Deciders:** GoodMao maintainers

> _Shipped: times are stored UTC and rendered/entered in an active timezone resolved per
> viewer (user preference → admin system default → `Etc/UTC`), backed by the pure-Elixir `tz`
> database. A user picks their zone on `/users/settings` (browser-prefilled); an admin sets the
> system default on `/admin/settings`._

## Context

Every datetime in GoodMao is stored UTC (`:utc_datetime`) — correct for storage. But the app
also **displayed** raw UTC: `format_datetime/1` / `format_date/1` ran `Calendar.strftime` with
no zone shift, and user-entered wall-clock times were frozen as UTC (Ecto casts a
`datetime-local` string as UTC; the report share-link parser hard-coded `Etc/UTC`). For any
viewer outside UTC this misreads **every** timeline entry, report timestamp, and calendar day —
"time recognition confusion." It is also a prerequisite for **medication reminders**, which
must fire at the right *local* time.

Three forces shaped the design:

1. **Storage stays UTC.** Shifting is a presentation and input-parsing concern, not a schema
   change — one instant, many local renderings.
2. **The viewer's zone must reach many call sites.** `format_datetime/1` is called across dozens
   of templates; threading a zone argument through all of them is noisy and easy to miss.
3. **A zone database is unavoidable.** Elixir needs a `Calendar.TimeZoneDatabase` to shift into
   arbitrary IANA zones; the standard library ships none.

## Decision

**Resolve an *active timezone* per viewer — user preference → admin system default → `Etc/UTC`
— and use it on both sides: shift stored UTC → local for display, and interpret user-entered
wall-clock → active zone → UTC for storage. Back it with the pure-Elixir `tz` database.**

- **`Goodmao2.Timezone` is the single policy module.** `resolve/1` answers "what zone applies
  to this viewer" from a `%User{}`/`%Scope{}`/`nil`. `all/0` lists the canonical IANA zones
  (derived from `tz`'s `zone1970.tab` at compile time) for the pickers; `known?/1` validates
  against the **live** database (so a browser-reported alias absent from the canonical list
  still passes). `to_local/2` and `local_naive_to_utc/2` are the two conversions (the latter
  resolving a spring-forward **gap** to the just-after instant and a fall-back **ambiguous**
  hour to the earlier one).

- **The active zone rides the process, mirroring locale.** `put_current/1` / `current/0` stash
  it in the process dictionary, exactly as `Gettext.put_locale` is process-scoped, so the view
  helpers shift without every call site passing a zone. `Goodmao2Web.Plugs.Timezone` (dead
  render, after `:fetch_current_scope_for_user`) and `Goodmao2Web.UserTimezone` (the LiveView
  `on_mount`, after the scope hook) establish it per request/socket and also `assign(:timezone)`
  for event handlers that parse submitted times.

- **Display shifts; `%Date{}` does not.** `format_datetime/1` / `format_date/1` shift a
  `%DateTime{}` into `current/0` before formatting (with `/2` arities for an explicit override);
  a `%Date{}` (report period, `ended_at`) is zoneless and left as-is. The machine-readable
  `<time datetime=…>` value stays UTC ISO-8601 — only the human text localizes.

- **Input parses in the active zone.** The log forms (`PetLive.Show`, `PetLive.LogEntry`)
  convert the `occurred_at` wall-clock via `local_naive_to_utc/2` **before** the changeset (Ecto
  would otherwise freeze it as UTC), and prefill the `datetime-local` input by shifting to local
  first. The report share-link parser uses the active zone instead of a hard-coded `Etc/UTC`.

- **The calendar buckets by local day.** `PetLive.Show` keys day cells and day-drill filtering
  by `to_local |> to_date`, and `CalendarGrid.grid_range/1` widens the UTC query window by a day
  on each side so entries near a local-midnight edge are still fetched to bucket (any IANA offset
  is < 24 h from UTC).

- **Two places set the zone.** A user picks a preferred IANA zone on `/users/settings` (a new
  nullable `users.timezone`, validated against `known?/1`, **browser-prefilled** once from
  `Intl.DateTimeFormat().resolvedOptions().timeZone`); an admin sets the system default on
  `/admin/settings` (the `Settings` key `"default_timezone"`). Nil preference falls through to
  the system default, then the configured `:goodmao2, :default_timezone` (itself `Etc/UTC`).

- **`tz`, not `tzdata`.** `tz` is pure Elixir and compiles the IANA data at build time with **no
  runtime HTTP**, so a locked-down deploy needs no outbound network for time math. Configured via
  `config :elixir, :time_zone_database, Tz.TimeZoneDatabase`.

## Consequences

- **Times read correctly for everyone**, and entry round-trips: a wall-clock entered in a zone
  stores the right UTC instant and renders back at the same local time. Switching a user's zone
  re-renders existing entries at the new local time (nothing stored is rewritten).
- **Low blast radius.** Because the active zone is process-scoped, making the whole app
  tz-aware was two helper changes plus per-request plumbing — existing `format_datetime/1` call
  sites were untouched.
- **The calendar window over-fetches by two days.** Harmless (out-of-grid buckets are ignored),
  and required for correct local-day cells; noted in `CalendarGrid`.
- **A new build-time dependency (`tz`)** and its IANA data, tracked by `check-updates`. The zone
  database ages; refreshing `tz` picks up new IANA releases.
- **Per-pet timezones are deferred.** Resolution is per *viewer*, not per pet — a pet's timeline
  reads in the caller's zone. A shared report opened anonymously renders in the system default.
- **DST edges are resolved deterministically** (gap → just-after, ambiguous → earlier), so a
  logged time never silently vanishes or double-counts.

## Alternatives considered

- **`tzdata`** — rejected in favour of `tz`: `tzdata` fetches and auto-updates the IANA database
  over HTTP at runtime, an awkward moving part and outbound dependency for a self-hosted app;
  `tz`'s build-time data is simpler and network-free.
- **Thread the zone through every `format_*` call** — rejected: dozens of noisy call-site edits
  and a forgotten one silently shows UTC. Process-scoping mirrors the locale mechanism already in
  the app and keeps the change small.
- **Store local time (or a zone) on each row** — rejected: storing UTC keeps one canonical
  instant; localizing at the edges is the standard, reversible approach and avoids rewriting
  history when a preference changes.
- **Display-only, leave input as UTC** — rejected: a half-tz-aware app (reads local, writes UTC)
  is *more* confusing than none; entering "8am" and seeing it stored as a different time is the
  exact failure this fixes.
- **Per-pet timezone now** — deferred: per-viewer resolution covers the confusion the maintainers
  raised; per-pet zones can layer on later via `resolve/1` without disturbing storage.
