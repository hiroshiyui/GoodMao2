# GoodMao — Architecture

_Last updated: 2026-07-20_

GoodMao is a single **Phoenix/LiveView** application: effortless structured daily
logging that becomes a shareable clinical timeline, built as an idiomatic
Elixir/Phoenix monolith — one server-rendered, real-time tier over Ecto + PostgreSQL.

## Contexts (`lib/goodmao2/`)

- **Accounts** (`accounts.ex`) — authentication and user management from `phx.gen.auth`,
  extended with the editable public **`@handle`**, `display_name`, and the
  first-user-becomes-**administrator** rule (`is_admin`). The administrator is the sole
  global role; it is orthogonal to per-pet access and grants no backdoor to pet data.
- **Pets** (`pets.ex`) — pets, access grants, and the **resource-based authorization**
  core. Authorization is computed per request from an *effective* grant, never global.
- **Logs** (`logs.ex`) — structured log entries, the timeline query (soft-delete-aware),
  and real-time broadcasts over PubSub.
- **Media** (`media.ex`) — purified photos/videos attached to `life` logs (ADR-0005):
  ffmpeg-based purification (`Media.Purifier`), an id-keyed storage seam (`Media.Storage`),
  atomic create with the log, an upload rate limiter (`Media.RateLimiter`), and the
  authorization for the serving endpoint.
- **Reports** (`reports.ex`) — generated, point-in-time **health summary reports** for a pet
  ([ADR-0012](adr/0012-vet-access-model.md)): a frozen `content` snapshot over a date range
  (built from `Logs.shareable_entries/3`, which **excludes every private entry**), read by any
  effective grant, and optionally shared through an **expiring** anonymous token.

Each context owns its schemas under `lib/goodmao2/<context>/`.

## Data model

### `users` (Accounts.User — extends the phx.gen.auth table)
`handle` (citext, unique), `display_name`, `is_admin`, plus the generated auth columns.

### `pets` (Pets.Pet)
Descriptive attributes (`name`, `species`, `breed`, `color`, `sex`, `birth_date`,
`neutered`, `weight_unit`). Ownership is **not** a column — it is a `pet_accesses` row
with role `owner`. `created_by_user_id` is an audit reference (no FK navigation).
`lifecycle_status` (`active` / `passed_away` / `rehomed` / `lost` / `other`) with
`ended_at`; end-of-care is a **status transition, not a deletion**. `history_hidden`
exists-hides the timeline.

### `pet_accesses` (Pets.PetAccess) — the authorization core
One row per `(pet, user)`. `role` ∈ {`owner`, `co_caretaker`, `viewer`, `vet`},
`status` ∈ {`active`, `revoked`}, optional `expires_at` (time-boxed grants, typical for
vets). Unique index on `(pet_id, user_id)`.

**Effective access** = `status == "active"` AND (`expires_at` is null OR in the future).

### `log_entries` (Logs.LogEntry) — one table, typed
Common columns (`pet_id`, `recorded_by_user_id` audit ref, `type`, `occurred_at`,
`note`, `visibility`, `deleted_at`) plus a `jsonb` **`data`** payload holding the
subtype's structured fields. `type` is the discriminator; per-type payload validation
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
- **Changing a log's `visibility` requires `owner`.**
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
- **Notifications** and the **mailbox** (`conversations` / `conversation_participants` /
  `messages`) are likewise deferred — see
  [ADR-0011](adr/0011-notifications-and-messaging.md). (**Log-edit revisions**, **VetProfile**,
  and **HealthSummaryReport** have shipped — see the data model above and
  [ADR-0009](adr/0009-log-edit-revisions.md) / [ADR-0012](adr/0012-vet-access-model.md).)

## Web layer (`lib/goodmao2_web/`)

LiveViews under `live/pet_live/`: `Index` (active / past pets), `Form` (new & edit),
`Show` (QuickLog + live timeline + weight trend), `LogEntry` (a single entry: edit + revision
history, ADR-0009), `Access` (sharing/grants), `EndOfCare` (owner-only lifecycle), `Reports`
(generate/list/view health summaries, ADR-0012). `UserLive.VetProfile` (`/users/vet-profile`)
is the applicant's credential-submission page. Routes live in the
`:require_authenticated_user` live_session in `router.ex`.
The `Show` LiveView subscribes to the pet's PubSub topic and streams entries.

`AdminLive` (`live/admin_live.ex`, `GET /admin`) is a separate `:require_admin`-gated,
read-only site-overview surface for the sole administrator (user count, admin identity,
first-registration gate status), plus the **veterinarian-credential review queue** (verify /
reject pending `VetProfile`s). Admin is a global role only — it grants **no** access to
pet data, so this page reads none.

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
