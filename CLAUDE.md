# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read these first

- **`AGENTS.md`** — the authoritative Elixir/Phoenix/LiveView/Ecto coding rules for this
  repo, plus a **GoodMao section** stating the invariants to preserve (authorization
  boundary, one-table logs, soft-delete, a11y, Gettext). Follow it.
- **`doc/architecture.md`** — contexts, data model (incl. per-`type` log payload fields),
  authorization table, and deferred entities.
- **`doc/roadmap.md`** — the product vision, the structured-logging core principle, and
  what's shipped vs. intentionally deferred.
- **`doc/glossary.md`** — the shared product/domain vocabulary (and its Phoenix tech terms).
- **`doc/adr/`** — Architecture Decision Records: the *why* behind the invariants
  (resource-based authorization, structured one-table logging, scope-based/first-user-admin
  auth, pet-lifecycle, log-visibility, error-reporting, soft-delete, second-factor auth,
  localization, timezone display, medication schedules, the Rust native boundary, deferred
  media/revisions/notifications).
- **`doc/web-application-development-common-practices.md`** — product-agnostic engineering
  lessons (security/data-modeling/testing/ops), each with the failure mode behind it.

## Commands

```bash
mix setup                      # deps + create/migrate DB + seed demo data + build assets
mix phx.gen.cert               # ONE-TIME: self-signed dev TLS cert in priv/cert/ (git-ignored)
mix phx.server                 # dev server: http://localhost:4000 + https://localhost:4001 (mailbox: /dev/mailbox)
iex -S mix phx.server          # same, with a REPL

mix precommit                  # THE gate: compile --warnings-as-errors + deps.unlock --unused + format + test
mix test                       # full suite (auto-creates/migrates the test DB)
mix test test/goodmao2/pets_test.exs           # one file
mix test test/goodmao2/pets_test.exs:42        # one test by line
mix test --failed                              # re-run last failures

mix ecto.gen.migration <name>  # ALWAYS generate migrations this way (correct timestamp)
mix ecto.migrate               # apply
mix ecto.reset                 # drop + recreate + migrate + seed
mix run priv/repo/seeds.exs    # re-seed (idempotent)

# i18n — after adding/changing any gettext() string:
mix gettext.extract && mix gettext.merge priv/gettext
```

**Rust NIFs** ([ADR-0017](doc/adr/0017-rust-nif-native-boundary.md))**:** `Goodmao2.Native`
loads the `native/goodmao2_native` crate (Rustler), built automatically by `mix compile` — the
toolchain is pinned by `rust-toolchain.toml`, so a build host needs that Rust version (`rustup`
auto-installs it). Currently only a placeholder `add/2` — proven scaffolding for future
CPU-bound work. `Cargo.lock` is committed; the built `priv/native/*.so` and `native/*/target/`
are git-ignored. Keep the `rustler` crate version in lockstep with the `:rustler` dep in `mix.exs`.

Postgres: dev and test both use a **`goodmao2`** role (password `goodmao2`) needing
`CREATEDB` — see `config/dev.exs` / `config/test.exs`. Demo logins after seeding:
`owner@example.com` / `vet@example.com`, both password `password1234!`.

## Architecture in one screen

GoodMao is a **single Phoenix/LiveView monolith** (no separate API/frontend). Domain
logic lives in four contexts under `lib/goodmao2/`; the web layer is thin LiveViews that
call them.

- **`Accounts`** (`accounts.ex`) — `phx.gen.auth` scope-based auth (the caller is
  `socket.assigns.current_scope.user`), extended with a public `@handle`, `display_name`,
  and `is_admin` (the **first registered user** becomes the sole administrator —
  [ADR-0016](doc/adr/0016-scope-based-auth-and-first-user-admin.md)). Admin is a
  global role only; it grants **no access to pet data**. Also the **second-factor** core
  ([ADR-0013](doc/adr/0013-second-factor-authentication.md)): `Accounts.TwoFactor` (TOTP via
  `nimble_totp` + `eqrcode`, single-use HMAC-hashed recovery codes, and `login_next_step/1`),
  `Accounts.WebAuthn` (FIDO2 security keys via `wax_`/`cbor`, sign-count regression enforced),
  the supervised single-use `Accounts.WebAuthnChallenges` ETS store, and `Accounts.TotpVault`
  (AES-256-GCM, keyed off `SECRET_KEY_BASE`). 2FA is **required for the admin**, opt-in for
  everyone else; secrets are encrypted/hashed at rest; security keys are **hard-deleted** (the
  soft-delete exception). The `:wax_` config (RP id/origin) lives in `config/{dev,test,runtime}.exs`.
- **`Pets`** (`pets.ex`) — pets, `pet_accesses` grants, and the **resource-based
  authorization core** ([ADR-0014](doc/adr/0014-resource-based-authorization.md)). This is
  the security-critical module:
  - Authorization is *computed per request* from an **effective grant** (`status=active`
    AND not expired), never global. Roles: `owner` / `co_caretaker` / `viewer` / `vet`;
    capability levels: `:read` / `:write` / `:manage`.
  - `Pets.can?(pet, user, level)` and `Pets.fetch_pet(user, id, require: level)` — the
    latter returns `{:error, :not_found}` for inaccessible pets (**IDOR-hidden**, never
    "forbidden").
  - Creating a pet inserts the creator's `owner` grant in the **same transaction**; the
    **≥1-owner invariant** is enforced on revoke (`{:error, :last_owner}`).
- **`Logs`** (`logs.ex`) — structured entries + the timeline + **PubSub**
  ([ADR-0015](doc/adr/0015-structured-one-table-logging.md)). All entry types
  share **one `log_entries` table** with a `type` discriminator and a `jsonb` `data`
  payload; per-type field validation is in `LogEntry.changeset/2`. Entries are
  **soft-deleted** (`deleted_at`); every read filters `deleted_at IS NULL`. Writes re-check
  `Pets` capability at the context boundary (`vet_note` is vet-only; changing `visibility`
  is owner-only). Setting an entry **`public`** (owner-only, on create *and* edit, timeline
  *and* media paths) mints an unguessable `share_token` via `Logs.put_share_token/1`; narrowing
  clears it. `fetch_entry_by_share_token/1` is the **sole anonymous read path** (still-public +
  unexpired `share_expires_at` + non-deleted + history not hidden, else existence-hidden) —
  [ADR-0004](doc/adr/0004-log-visibility.md). Each real edit snapshots the prior state into `log_entry_revisions`
  (append-only, edit-count-capped). `create/update/delete_entry` broadcast on the pet's
  topic so `PetLive.Show` streams live updates.
- **`Medications`** (`medications.ex`) — recurring medication **schedules** + materialized
  **dose** slots + reminders ([ADR-0019](doc/adr/0019-medication-schedules-and-reminders.md)).
  Each schedule stores its own IANA `timezone`; `materialize_doses/1` pre-creates one durable
  `medication_doses` row per upcoming slot (wall-clock → UTC, idempotent via a unique
  `(schedule_id, due_at)` index). Marking a dose given is an **atomic `pending → given` claim**
  (TOCTOU-safe; second caller → `{:error, :already_recorded}`) that reuses the `medication`
  `log_entry` via `Logs.create_entry` — one timeline, no parallel history. Create/edit a schedule
  and give/skip a dose need **`:write`**; delete needs **`:manage`**. `Medications.ReminderWorker`
  (Oban cron, `*/15`) fills the horizon, ages overdue slots to `missed`, and fans out a
  **`medication_due`** bell + Web Push to effective `:write` caretakers, de-duped via `reminded_at`.
  Web UI: `PetLive.Medications` (`/pets/:pet_id/medications`), linked from the pet page.
- **`Media`** (`media.ex`) — purified LifeLog photos/videos attached to `life` logs
  ([ADR-0005](doc/adr/0005-media-storage.md)). `Media.Purifier` re-encodes/remuxes uploads
  with **ffmpeg** (magic-byte typing, EXIF/GPS stripped, codec allow-list + duration cap);
  `Media.Storage` writes id-keyed opaque objects under a configured `storage_dir` (the
  physical path is never stored — traversal-proof); assets are created atomically with the
  log and re-authorized per request. `Media.RateLimiter` throttles uploads.
- **`Reports`** (`reports.ex`) — generated **health summary reports**
  ([ADR-0012](doc/adr/0012-vet-access-model.md)). `generate_report/3` (`:manage`) freezes a
  `jsonb` `content` snapshot over a date range built from `Logs.shareable_entries/3`, which
  **excludes every `private` entry** so the snapshot is safe to share. Reading needs `:read`;
  an optional **expiring** share link stores only the token's SHA-256 hash. Also:
  **`Accounts.VetProfile`** — the `vet` role is grantable only to a user with a **verified**
  profile (`Accounts.verified_vet?/1`), gated in `Pets.grant_access/3` on grant *and* re-grant.
- **`Notifications`** (`notifications.ex`) — the in-site **bell feed** ([ADR-0011](doc/adr/0011-notifications-and-messaging.md)).
  Per-recipient rows keyed by `type` + a `jsonb` payload; **copy is rendered at read time**
  (`Goodmao2Web.Helpers.notification_summary/1`), never stored. Grant/revoke notify **inline**
  from `Pets`; `log_added` (respecting per-entry `visibility`) and admin `announcement`s fan out
  via **Oban** (`LogFanoutWorker` / `AnnouncementFanoutWorker`). Every change broadcasts the
  recomputed unread count over PubSub. **Web Push** (ADR-0011 Stage 2) rides the same rows:
  every bell row funnels through `create/3`, which enqueues a **`PushDispatchWorker`** when
  `WebPush.vapid_configured?/0`. `WebPush` hand-rolls RFC 8291/8188/8292 on `:crypto` (no
  external lib); `WebPush.SafeClient` is an **SSRF-safe, DNS-pinned** outbound client
  (private-range denylist incl. IPv4-mapped/NAT64) validating the browser-supplied `endpoint`
  at storage *and* send time; `WebPush.VapidVault` AES-256-GCM-encrypts the VAPID private key
  (keyed off `SECRET_KEY_BASE`). Browsers subscribe via `PushSubscriptionController`
  (`/api/push-subscriptions`, CSRF + rate-limited); `service_worker.js` + `push_manager_hook.js`
  drive display and opt-in (on `/users/settings`).
- **`Settings`** (`settings.ex`) — a tiny admin-managed key/value system-settings store
  (ETS-cached via `Settings.Cache`), used for the **VAPID keypair** and the **system default
  timezone** (`default_timezone`). An admin manages these on **`AdminLive.Settings`**
  (`/admin/settings`). Reads are unauthenticated; writes are admin-gated at the LiveView boundary.
- **`Timezone`** (`timezone.ex`) — timezone policy ([ADR-0018](doc/adr/0018-timezone-display-policy.md)).
  Times are stored **UTC** but resolved to an **active zone per viewer** — `resolve/1`:
  **user `timezone` preference → `Settings` `default_timezone` → `Etc/UTC`**. The active zone is
  process-scoped like Gettext locale (`put_current/1` / `current/0`), established by
  `Plugs.Timezone` (`:browser`, after scope fetch) and the `UserTimezone` `on_mount` (after the
  scope hook, in each authed live_session). `format_datetime/1`/`format_date/1` shift UTC → local;
  the log forms parse `occurred_at` wall-clock → UTC via `local_naive_to_utc/2` **before** the
  changeset; the calendar buckets by **local** day (`grid_range/1` over-fetches ±1 day). Backed by
  the pure-Elixir **`tz`** dep (no runtime HTTP; `config :elixir, :time_zone_database`). A user
  picks their zone on `/users/settings` (browser-prefilled via the `TimezoneDetect` hook).
- **`Messaging`** (`messaging.ex`) — private **1:1 mailbox** ([ADR-0011](doc/adr/0011-notifications-and-messaging.md)).
  One conversation per unordered user pair (canonical `user_lo_id < user_hi_id`, DB `CHECK` +
  unique index). **Shared-pet gate:** `start_conversation/2` is allowed only between users with
  an effective grant on a common pet, returning a uniform non-leaking `{:error, :cannot_message}`
  whether the recipient is unknown, self, or unshared. Thread reads require participation
  (existence-hidden `nil`/`:not_participant`); each participant has a **read cursor**; messages
  are capped at 2 000 codepoints and soft-deleted. A new message also **Web Push**es to the other
  participant (`send_message/3` → `MessagePushWorker` → `Notifications.push_to_user/2`), gated on
  `WebPush.vapid_configured?/0` — messages write no bell row, so this is their only push path.

Web LiveViews (`lib/goodmao2_web/live/pet_live/`): `Index`, `Form` (new/edit), `Show`
(QuickLog + live filterable, page-sized timeline/calendar + weight trend), `LogEntry` (single entry:
edit + revision history), `Access` (grant/revoke), `EndOfCare` (owner-only lifecycle),
`Reports` (generate/list/view health summaries). `UserLive.VetProfile` (`/users/vet-profile`)
submits vet credentials. **Two-factor** ([ADR-0013](doc/adr/0013-second-factor-authentication.md)):
`UserLive.TwoFactorSettings` (`/users/settings/two-factor`, sudo-gated) manages TOTP + security
keys + recovery codes; the login challenge/setup pages (`UserLive.TwoFactor`,
`TwoFactorSetup`, `TwoFactorRecovery`) live in the `:two_factor` live_session gated by the
`:require_pending_2fa` on_mount (the user has passed primary auth but holds **no session token
yet**); `UserTwoFactorController` authoritatively re-verifies each factor and only then issues the
token (`POST /users/two-factor/{totp,recovery,webauthn,complete}`). `NotificationLive.Index` (`/notifications`) is the bell feed;
`MessageLive.Index`/`Show` (`/messages`, `/messages/:id`) are the mailbox. Live nav **unread
badges** come from the global `Goodmao2Web.UnreadBadges` `on_mount` hook (`attach_hook`) on the
authenticated live_session — no per-LiveView code. `AdminLive` (`live/admin_live.ex`) is the
admin-only read-only `/admin` site overview **and** the vet-credential review queue;
`AdminLive.Announcements` (`/admin/announcements`) composes announcement broadcasts, and
`AdminLive.Settings` (`/admin/settings`) generates/manages the Web Push VAPID keys.
They authorize in `mount` via `Pets.fetch_pet/3` and `push_navigate` on failure. Purified
media is served by `MediaController` at `GET /media/:id` (re-applies the parent log's read
authorization, IDOR-hidden, hardened headers, `Range` support), and anonymously for a `public`
entry by `MediaController.shared` at `GET /entries/shared/:token/media/:id` (token-gated, same
hardening); anonymous shared reports by `ReportController` at `GET /reports/shared/:token` and a
single anonymous **shared entry** by `SharedEntryController` at `GET /entries/shared/:token`
(both unexpired-token-gated, existence-hidden — [ADR-0004](doc/adr/0004-log-visibility.md)); Web
Push subscriptions by `PushSubscriptionController` (`POST`/`DELETE /api/push-subscriptions`,
through the `:browser` pipeline for CSRF, rate-limited). The owner manages an entry's share link
(copy URL, set/clear expiry) on `PetLive.LogEntry`; the `Clipboard` JS hook backs the copy button.
Routes are in the `:require_authenticated_user` `live_session` in `router.ex`. Shared view
helpers (enum-label translations, log summaries, clinical flags) are in
`lib/goodmao2_web/helpers.ex`; the health-report body + shared weight chart are in
`lib/goodmao2_web/components/report_components.ex` — all imported app-wide via `goodmao2_web.ex`.

## Non-obvious conventions

- **End-of-care is a lifecycle status transition, not a deletion** — the pet record and
  its timeline are always preserved. `Index` separates active vs. past pets.
- **Do not hard-delete log entries**; stamp `deleted_at`.
- Audit-only user references (`recorded_by_user_id`, `granted_by_user_id`,
  `created_by_user_id`) are plain id columns **without FK navigations** (deliberate — avoids
  multiple cascade paths).
- Every user-visible string goes through `gettext()`; keep `en` / `zh_TW` / `ja_JP` in
  sync. Every meaningful template element carries a stable semantic `id`/`class` (loop items
  derive an id from the record) — this is used by the LiveView tests.
- **Every route assigns a `page_title`** (localized, bare). The root layout's `<.live_title>`
  appends the ` · GoodMao` suffix *unconditionally*, so a page without a title renders
  `GoodMao · GoodMao`. Set it in `mount` (LiveView) or before `render/2` (controller), usually
  matching the page's `<.header>` text; never assign the bare brand as the title.
- Tests mirror `lib/` under `test/`: `use Goodmao2.DataCase` for contexts, `use
  Goodmao2Web.ConnCase` (+ `setup :register_and_log_in_user`) for LiveViews. Pet/log test
  data comes from `Goodmao2.PetsFixtures`.
