# GoodMao — Architecture

_Last updated: 2026-07-20_

GoodMao is a single **Phoenix/LiveView** application: effortless structured daily
logging that becomes a shareable clinical timeline, built as an idiomatic
Elixir/Phoenix monolith — one server-rendered, real-time tier over Ecto + PostgreSQL.

## Contexts (`lib/goodmao2/`)

- **Accounts** (`accounts.ex`) — authentication and user management from `phx.gen.auth`,
  extended with the editable public **`@handle`**, `display_name`, and the
  first-user-becomes-**administrator** rule (`is_admin`) ([ADR-0016](adr/0016-scope-based-auth-and-first-user-admin.md)).
  The administrator is the sole global role; it is orthogonal to per-pet access and grants
  no backdoor to pet data.
  Also the **second-factor** core ([ADR-0013](adr/0013-second-factor-authentication.md)):
  `Accounts.TwoFactor` (TOTP + single-use HMAC-hashed recovery codes + the `login_next_step/1`
  state machine), `Accounts.WebAuthn` (FIDO2 relying-party ceremonies via `wax_`, sign-count
  regression enforced), the supervised single-use `Accounts.WebAuthnChallenges` ETS store, and
  `Accounts.TotpVault` (AES-256-GCM secret-at-rest, keyed off `SECRET_KEY_BASE`). 2FA is
  **required for the admin**, opt-in for everyone else.
- **Pets** (`pets.ex`) — pets, access grants, and the **resource-based authorization**
  core ([ADR-0014](adr/0014-resource-based-authorization.md)). Authorization is computed
  per request from an *effective* grant, never global.
- **Logs** (`logs.ex`) — structured log entries ([ADR-0015](adr/0015-structured-one-table-logging.md)),
  the timeline query (soft-delete-aware), and real-time broadcasts over PubSub.
- **Medications** (`medications.ex`) — recurring medication **schedules** + materialized **dose**
  slots + reminders ([ADR-0019](adr/0019-medication-schedules-and-reminders.md)). Dose slots are
  pre-created per schedule (in the schedule's own timezone → UTC); marking a dose given is an
  **atomic `pending → given` claim** that reuses the `medication` `log_entry` (`Logs.create_entry`).
  `Medications.ReminderWorker` (Oban cron) fills the horizon, ages overdue slots to `missed`, and
  fans out a `medication_due` bell + Web Push to effective `:write` caretakers, de-duped.
- **Media** (`media.ex`) — purified photos/videos attached to `life` logs (ADR-0005):
  ffmpeg-based purification (`Media.Purifier`), an id-keyed storage seam (`Media.Storage`),
  atomic create with the log, an upload rate limiter (`Media.RateLimiter`), and the
  authorization for the serving endpoint.
- **Reports** (`reports.ex`) — generated, point-in-time **health summary reports** for a pet
  ([ADR-0012](adr/0012-vet-access-model.md)): a frozen `content` snapshot over a date range
  (built from `Logs.shareable_entries/3`, which **excludes every private entry**), read by any
  effective grant, and optionally shared through an **expiring** anonymous token.
- **Notifications** (`notifications.ex`) — the in-site **bell feed** ([ADR-0011](adr/0011-notifications-and-messaging.md)):
  per-recipient rows with a `type` + `jsonb` payload (copy rendered at read time, never
  stored). Single-recipient grant/revoke events are created **inline** by `Pets`;
  `log_added` (visibility-aware) and admin `announcement`s fan out via **Oban**
  (`LogFanoutWorker` / `AnnouncementFanoutWorker`). Every change broadcasts the recomputed
  unread count over PubSub. **Web Push** (Stage 2) rides the same rows: `create/3` enqueues a
  `PushDispatchWorker` when VAPID is configured. `WebPush` hand-rolls RFC 8291/8188/8292 on
  `:crypto`; `WebPush.SafeClient` is the SSRF-safe, DNS-pinned outbound client; `WebPush.VapidVault`
  encrypts the private key. Browsers subscribe via `PushSubscriptionController`; a root-scope
  `service_worker.js` shows the notification.
- **Settings** (`settings.ex`) — a tiny admin-managed key/value system-settings store (ETS-cached),
  holding the Web Push VAPID keypair and the **system default timezone**; managed on
  `AdminLive.Settings` (`/admin/settings`).
- **Timezone** (`timezone.ex`) — timezone policy ([ADR-0018](adr/0018-timezone-display-policy.md)):
  resolves the active zone per viewer (**user preference → system default → `Etc/UTC`**),
  process-scoped like locale via a `:browser` plug (`Plugs.Timezone`) and a LiveView `on_mount`
  (`UserTimezone`). Times are stored UTC and shifted to the active zone for display / parsed from
  it on input; backed by the pure-Elixir `tz` database (no runtime HTTP).
- **Messaging** (`messaging.ex`) — private **1:1 mailbox** ([ADR-0011](adr/0011-notifications-and-messaging.md)):
  one conversation per unordered user pair, gated by the **shared-pet rule** (`can_message?/2`,
  the effective-grant self-join) with a uniform non-leaking `:cannot_message`; thread reads
  require participation (existence-hidden), each participant carries a **read cursor**, and
  messages (2 000-codepoint cap) broadcast live per conversation.

Each context owns its schemas under `lib/goodmao2/<context>/`.

## Data model

### `users` (Accounts.User — extends the phx.gen.auth table)
`handle` (citext, unique), `display_name`, `is_admin`, plus the generated auth columns.
Two-factor columns (ADR-0013): `totp_secret` (AES-256-GCM ciphertext, never plaintext) and
`totp_confirmed_at` (nil ⇒ TOTP disabled). `timezone` (nullable IANA zone; nil ⇒ fall back to
the admin system default, then `Etc/UTC` — [ADR-0018](adr/0018-timezone-display-policy.md)).

### `webauthn_credentials` (Accounts.WebAuthnCredential) — FIDO2 security keys
One row per enrolled key: `credential_id` (unique — the lookup key), `public_key_cbor` (COSE
key), `sign_count` (clone detection, must not regress), `aaguid`, `label`, `last_used_at`.
**Hard-deleted** on removal (the soft-delete exception — a revoked credential must never
authenticate). See [ADR-0013](adr/0013-second-factor-authentication.md).

### `recovery_codes` (Accounts.RecoveryCode) — 2FA backup codes
Ten single-use codes backing up TOTP. Stored only as an **HMAC-SHA256** `code_hash` (keyed off
`SECRET_KEY_BASE`); `used_at` stamps consumption. Regenerating deletes the prior set.

### `pets` (Pets.Pet)
Descriptive attributes (`name`, `species`, `breed`, `color`, `sex`, `birth_date`,
`neutered`, `weight_unit`). Ownership is **not** a column — it is a `pet_accesses` row
with role `owner`. `created_by_user_id` is an audit reference (no FK navigation).
`lifecycle_status` (`active` / `passed_away` / `rehomed` / `lost` / `other`) with
`ended_at`; end-of-care is a **status transition, not a deletion**. `history_hidden`
exists-hides the timeline.

### `pet_accesses` (Pets.PetAccess) — the authorization core
([ADR-0014](adr/0014-resource-based-authorization.md).) One row per `(pet, user)`. `role` ∈ {`owner`, `co_caretaker`, `viewer`, `vet`},
`status` ∈ {`active`, `revoked`}, optional `expires_at` (time-boxed grants, typical for
vets). Unique index on `(pet_id, user_id)`.

**Effective access** = `status == "active"` AND (`expires_at` is null OR in the future).

### `log_entries` (Logs.LogEntry) — one table, typed
([ADR-0015](adr/0015-structured-one-table-logging.md).)
Common columns (`pet_id`, `recorded_by_user_id` audit ref, `type`, `occurred_at`,
`note`, `visibility`, `deleted_at`, and — for a `public` entry — a `share_token` +
optional `share_expires_at`, [ADR-0004](adr/0004-log-visibility.md)) plus a `jsonb`
**`data`** payload holding the subtype's structured fields. `type` is the discriminator; per-type payload validation
lives in `LogEntry.changeset/2`. Soft-deleted via `deleted_at` (reads filter
`deleted_at IS NULL`). `occurred_at` (when the event happened) is distinct from the
row's insert time and is **backdatable**; future timestamps are rejected.

The `data` payload per `type` (validated in `LogEntry.changeset/2`):

| `type` | `data` fields |
|---|---|
| `food` | `amount` (`full` / `partial` / `refused`), `food_type?`, `portion_grams?` |
| `water` | `amount` (`normal` / `low` / `high`), `volume_ml?` |
| `bathroom` | `kind` (`urine` / `stool`), `consistency?`, `has_blood`, `is_straining` (⚠ cat urinary-emergency signal) |
| `vomit` | `count`, `contents?` |
| `weight` | `weight_grams` (rendered in the pet's `weight_unit`) |
| `energy` | `level` (1–5), `mood?` |
| `medication` | `medication_name`, `dose`, `administered_at` (later: FK to a `medications` schedule) |
| `symptom` | `symptom`, `severity` (1–5) |
| `vet_note` | `assessment`, `recommendation` — vet-authored, authoritative timeline note |
| `life` | daily-life note — the required caption is the base `note` (photo/video enrichment deferred). Backdatable like any log |

Range-checked scales (1–5) and non-negative quantities are validated for *meaning*, not
just type. See [`glossary.md`](glossary.md) for the domain terms.

An entry also carries a denormalized `edit_count` (0–9). Each **real** edit refuses to
exceed nine (`{:error, :edit_limit}`), snapshots the entry's prior state, and increments the
count — see revisions below.

### `log_entry_revisions` (Logs.LogEntryRevision) — the edit audit trail

An immutable, append-only snapshot written on each real edit ([ADR-0009](adr/0009-log-edit-revisions.md)):
a `jsonb` `snapshot` of the entry as it stood *before* the edit (`type` + `data` + `note` +
`occurred_at` + `visibility`, never the share token), `edited_by_user_id` (audit ref) and its
insert time, plus a denormalized `pet_id` for scoping. Rows are never edited or deleted and
ride the parent entry's soft-delete. History uses the **same read authorization as the entry**
(any effective grant, private-entry and hidden-history rules apply).

### `media_assets` (Media.MediaAsset) — purified life-log media

Metadata for a purified photo/video attached to a `life` log ([ADR-0005](adr/0005-media-storage.md)):
`log_entry_id` (FK, cascade), a **denormalized `pet_id`** (the authorization anchor — there
is no `pet_id` in the serving URL to forge), `kind` (image/video), the magic-byte-validated
`content_type`, `byte_size`, uploader, optional caption. **The physical path is derived from
the id and never stored** (path-traversal-proof). Bytes are re-encoded/remuxed by ffmpeg to
strip EXIF/GPS/metadata, written under a configured `storage_dir` outside any served path, and
inserted with the log in one transaction. Soft-deleted via `deleted_at`.

### `medication_schedules` / `medication_doses` (Medications.*) — schedules + dose slots

A recurring medication plan and its materialized dose slots ([ADR-0019](adr/0019-medication-schedules-and-reminders.md)).
A **schedule** carries `medication_name`, `dose`, `times_of_day` (`time[]`), `interval_days`,
`start_date`/`end_date`, its own IANA `timezone`, `active`, `notes`, and an audit
`created_by_user_id`; soft-deleted via `deleted_at`. A **dose** is one durable slot per expected
time: `schedule_id` (FK), a **denormalized `pet_id`** (authorization anchor), `due_at` (UTC, from
the schedule's wall-clock time + `timezone`), `status` (`pending | given | skipped | missed`),
`given_at`, audit `recorded_by_user_id`, a `log_entry_id` link (the `medication` entry written on
give), and `reminded_at` (nudge de-dupe). A **unique `(schedule_id, due_at)`** index makes
materialization idempotent; a partial index over pending slots backs the reminder sweep. Marking a
dose given is an atomic `pending → given` claim (no double-dose).

### `vet_profiles` (Accounts.VetProfile) — veterinarian credential

At most **one** per user: `license_number`, `licensing_body`, `region`, `clinic_name`,
`specialty?`, `verification_status` (`pending` / `verified` / `rejected`), `verified_at?`,
`verified_by_admin_id?` (audit ref, no FK navigation). A (re)submission returns the profile to
`pending`. The per-pet `vet` role is granted only to a user with a **verified** profile —
enforced in `Pets.grant_access/3` on grant *and* re-grant ([ADR-0012](adr/0012-vet-access-model.md)).

### `health_summary_reports` (Reports.HealthSummaryReport) — generated summary

Per pet: `period_start` / `period_end`, `generated_by_user_id` (audit ref), a `jsonb`
**`content`** snapshot (frozen at generation — pet descriptor + shareable entries, private
entries omitted), an optional `share_token_hash` (SHA-256 of the raw token, shown once) always
paired with `share_expires_at`, and `deleted_at` (soft-delete). Generation/sharing/deletion
require `:manage`; reading requires `:read`; the anonymous token path is gated only by an
unexpired, matching token. See [ADR-0012](adr/0012-vet-access-model.md).

### `notifications` (Notifications.Notification) — the bell feed

Per recipient: `user_id`, a `type` discriminator (`access_granted` / `access_revoked` /
`log_added` / `announcement` / `medication_due`), a `jsonb` **`payload`** (denormalized snapshot — pet id/name,
actor label, role, log type + entry id, announcement title/body; the copy is *rendered* from
this at read time, never stored), `read_at?` (null = unread), and `deleted_at`. A partial index
on unread rows backs the badge count. See [ADR-0011](adr/0011-notifications-and-messaging.md).

### `conversations` / `conversation_participants` / `messages` (Messaging.*) — the mailbox

One `conversations` row per **unordered user pair** — stored as ordered `user_lo_id` <
`user_hi_id` columns (DB `CHECK` + unique index; the canonical pair key), plus a denormalized
`last_message_at`. Each `conversation_participants` row is one user's membership and carries the
per-participant **read cursor** `last_read_at` (a message is unread when it arrived after it).
`messages` hold `conversation_id`, `sender_id` (audit ref, nilified on user deletion), and a
`body` capped at **2 000** characters (column + changeset). All three soft-delete via
`deleted_at`. Starting a conversation is gated by the **shared-pet rule**; thread access
requires participation. See [ADR-0011](adr/0011-notifications-and-messaging.md).

### `push_subscriptions` (Notifications.PushSubscription) — Web Push endpoints

Per browser/device: `user_id`, the push-service `endpoint` (browser-supplied — **SSRF-validated**
to a public HTTPS host before storage; globally unique), the subscriber's `p256dh` (65 B) + `auth`
(16 B) keys (raw binary, for RFC 8291 encryption), `user_agent?`, and `deleted_at` (a 410/410-gone
endpoint is soft-deleted on the next send). See [ADR-0011](adr/0011-notifications-and-messaging.md) §Web Push.

### `settings` (Settings.Setting) — admin-managed system settings

A tiny global key/value store (`key` unique, `value` text) an administrator manages from
`/admin/settings`; ETS-cached for reads. Occupants: the Web Push VAPID keypair —
`vapid_public_key` (plain), `vapid_private_key_encrypted` (AES-256-GCM via `WebPush.VapidVault`,
keyed off `SECRET_KEY_BASE`), `vapid_subject` — and `default_timezone`, the system default zone
([ADR-0018](adr/0018-timezone-display-policy.md)).

## Authorization logic

`Goodmao2.Pets.can?(pet, user, level)` where `level` ∈ `:read | :write | :manage`:

| Role | `:read` | `:write` | `:manage` |
|---|:---:|:---:|:---:|
| `owner` | ✅ | ✅ | ✅ |
| `co_caretaker` | ✅ | ✅ | — |
| `vet` | ✅ | ✅ (authors `vet_note`) | — |
| `viewer` | ✅ | — | — |

- **Pet CRUD, lifecycle, and grant management require `:manage`** (owner).
- **Log authoring requires `:write`**; `vet_note` additionally requires the `vet` role
  (enforced in `Logs`, the context boundary).
- **The `vet` role is granted only to a verified `VetProfile`** (`Accounts.verified_vet?/1`),
  on grant *and* re-grant ([ADR-0012](adr/0012-vet-access-model.md)).
- **Changing a log's `visibility` requires `owner`** (and creating a `public` entry does too);
  setting `public` mints a revocable `share_token` — the sole anonymous read path
  (`Logs.fetch_entry_by_share_token/1`, `GET /entries/shared/:token`), [ADR-0004](adr/0004-log-visibility.md).
- `Pets.fetch_pet/3` returns `{:error, :not_found}` (never "forbidden") for pets the
  caller cannot access — **IDOR-hidden**.
- **Owner invariant:** creating a pet inserts the creator's `owner` grant in the same
  transaction; revoking/expiring the last effective owner is refused (`{:error, :last_owner}`).

## Deferred / future entities

Planned for later phases; **not yet in GoodMao's
schema**. Recorded here so the payload/relationship shapes are known when the work lands
(see [`roadmap.md`](roadmap.md) and the linked ADRs).

- **Medication** (per pet) — an ongoing prescription/schedule (`name`, `dose`, `route?`,
  `schedule` recurrence, `start_date`, `end_date?`, `prescribed_by_vet_id?` audit ref,
  `active`). `medication` log entries record actual administrations against it — the
  "did anyone give the pill?" coordination. _Phase 1/3._
- (**Log-edit revisions**, **VetProfile**, **HealthSummaryReport**, **notifications**, the
  **mailbox**, and **Web Push** (ADR-0011 Stage 2) have all shipped — see the data model above
  and [ADR-0009](adr/0009-log-edit-revisions.md) /
  [ADR-0011](adr/0011-notifications-and-messaging.md) / [ADR-0012](adr/0012-vet-access-model.md).)

## Web layer (`lib/goodmao2_web/`)

LiveViews under `live/pet_live/`: `Index` (active / past pets), `Form` (new & edit),
`Show` (QuickLog + live timeline + weight trend), `LogEntry` (a single entry: edit + revision
history, ADR-0009), `Access` (sharing/grants), `EndOfCare` (owner-only lifecycle), `Reports`
(generate/list/view health summaries, ADR-0012). `UserLive.VetProfile` (`/users/vet-profile`)
is the applicant's credential-submission page. `NotificationLive.Index` (`/notifications`) is
the bell feed, and `MessageLive.Index` / `MessageLive.Show` (`/messages`, `/messages/:id`) are
the mailbox inbox and thread (ADR-0011). Routes live in the `:require_authenticated_user`
live_session in `router.ex`.
The `Show` LiveView subscribes to the pet's PubSub topic and streams entries.

**Two-factor** ([ADR-0013](adr/0013-second-factor-authentication.md)):
`UserLive.TwoFactorSettings` (`/users/settings/two-factor`, sudo-gated) manages the
authenticator app, security keys, and recovery codes. The login-time challenge/setup pages
(`UserLive.TwoFactor`, `TwoFactorSetup`, `TwoFactorRecovery`) live in a **separate
`:two_factor` live_session** gated by the `:require_pending_2fa` on_mount — the user has passed
primary auth but holds **no session token yet**. `UserTwoFactorController`
(`POST /users/two-factor/{totp,recovery,webauthn,complete}`, `:browser` pipeline for CSRF)
re-verifies each factor authoritatively, throttles/locks out attempts, and only then issues the
token via `UserAuth.complete_2fa_login/2`. The `WebAuthn` JS hook (`assets/js/webauthn_hook.js`)
drives `navigator.credentials.create`/`get`, sharing base64url helpers with the Web Push hook.

Live **unread badges** in the nav come from a global `Goodmao2Web.UnreadBadges` `on_mount`
hook on that live_session: it assigns the counts and `attach_hook(:handle_info, …)` updates
them from PubSub in **every** authenticated LiveView without per-view code
([ADR-0011](adr/0011-notifications-and-messaging.md)).

`AdminLive` (`live/admin_live.ex`, `GET /admin`) is a separate `:require_admin`-gated,
read-only site-overview surface for the sole administrator (user count, admin identity,
first-registration gate status), plus the **veterinarian-credential review queue** (verify /
reject pending `VetProfile`s). `AdminLive.Announcements` (`/admin/announcements`, same
`:require_admin` gate) composes an admin **announcement** broadcast to every user. Admin is a
global role only — it grants **no** access to pet data, so these pages read none.

Purified life-log media is served by `MediaController` at `GET /media/:id` (a dedicated
`:serve_media` pipeline — session + scope, no HTML negotiation), which re-applies the parent
log's read authorization, hides existence with `not_found`, sets hardened headers, and
supports `Range`. Uploads flow through `PetLive.Show` (LiveView `allow_upload`) and never hand
the browser a direct storage URL.

`ReportController` serves an anonymous, print-friendly health summary at
`GET /reports/shared/:token` (the `:browser` pipeline, no authentication). It renders a report's
frozen snapshot only for an unexpired, matching share token — a bad, expired, or revoked token
is `not_found` (existence-hidden). The snapshot never contains private entries, so no per-pet
authorization is needed to render it.

### Conventions carried from `baudrate`

- **Accessibility-first:** every meaningful element carries a stable, semantic `id`/`class`
  (loop items derive an id from the record), for tooling, testing, and styling.
- **All user-visible copy through Gettext**, including flash messages and `aria-*`. Enum
  label translations and log summaries live in `Goodmao2Web.Helpers`.
- **`mix precommit`** (compile-warnings-as-errors + unused-deps + format + test) is the gate.
- Tests mirror `lib/` under `test/`; contexts use `DataCase`, LiveViews use `ConnCase`.
