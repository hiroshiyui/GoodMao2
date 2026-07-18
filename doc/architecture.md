# GoodMao2 — Architecture

_Last updated: 2026-07-18_

GoodMao2 is the **Phoenix/LiveView** rendering of GoodMao. The product is unchanged
— effortless structured daily logging that becomes a shareable clinical timeline —
but the architecture is idiomatic Elixir/Phoenix rather than a decoupled two-tier
web app.

## Technology mapping (GoodMao → GoodMao2)

| GoodMao (original) | GoodMao2 (Phoenix) | Notes |
|---|---|---|
| SvelteKit BFF + ASP.NET Core JSON API | **Phoenix LiveView** monolith | one tier, server-rendered, real-time |
| ASP.NET Core Identity + cookie BFF | **`phx.gen.auth`** scope-based auth | `current_scope.user`; magic-link + password |
| EF Core 10 + PostgreSQL | **Ecto + PostgreSQL** | `jsonb` for species-specific / typed payloads |
| Log entries via TPH (one table, discriminator) | **one `log_entries` table + `type` + `jsonb data`** | typed validation in the schema, not TPH classes |
| Resource-based authorization handlers | **`Goodmao2.Pets` capability functions + LiveView mount checks** | `can?/3`, effective-grant resolution |
| Custom DB-backed background-job queue | **(deferred — Oban when needed)** | not required by the MVP core |
| Notifications polling + BFF relay | **Phoenix PubSub** | live timeline today; notification feed deferred |
| Paraglide i18n (two tiers) | **Gettext** | `en` / `zh_TW` / `ja_JP` |
| UIkit (Less) + Roboto Slab | **Tailwind v4 + daisyUI** | from the `phx.new` scaffold |

## Contexts (`lib/goodmao2/`)

- **Accounts** (`accounts.ex`) — authentication and user management from `phx.gen.auth`,
  extended with the editable public **`@handle`**, `display_name`, and the
  first-user-becomes-**administrator** rule (`is_admin`). The administrator is the sole
  global role; it is orthogonal to per-pet access and grants no backdoor to pet data.
- **Pets** (`pets.ex`) — pets, access grants, and the **resource-based authorization**
  core. Authorization is computed per request from an *effective* grant, never global.
- **Logs** (`logs.ex`) — structured log entries, the timeline query (soft-delete-aware),
  and real-time broadcasts over PubSub.

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
- **Changing a log's `visibility` requires `owner`.**
- `Pets.fetch_pet/3` returns `{:error, :not_found}` (never "forbidden") for pets the
  caller cannot access — **IDOR-hidden**.
- **Owner invariant:** creating a pet inserts the creator's `owner` grant in the same
  transaction; revoking/expiring the last effective owner is refused (`{:error, :last_owner}`).

## Deferred / future entities

Modeled in the original GoodMao and planned for later phases; **not yet in GoodMao2's
schema**. Recorded here so the payload/relationship shapes are known when the work lands
(see [`roadmap.md`](roadmap.md) and the linked ADRs).

- **VetProfile** (0..1 per user) — the account-level proof of veterinarian status:
  `license_number`, `licensing_body`, `region`, `clinic_name`, `specialty?`,
  `verification_status` (`pending` / `verified` / `rejected`), `verified_at?`,
  `verified_by_admin_id?` (audit ref). "Vet" as a per-pet role requires a verified
  profile. _Phase 4._
- **Medication** (per pet) — an ongoing prescription/schedule (`name`, `dose`, `route?`,
  `schedule` recurrence, `start_date`, `end_date?`, `prescribed_by_vet_id?` audit ref,
  `active`). `medication` log entries record actual administrations against it — the
  "did anyone give the pill?" coordination. _Phase 1/3._
- **HealthSummaryReport** (per pet) — a generated point-in-time export of logs in a
  range (`period_start`, `period_end`, `generated_by_user_id`), optionally shared via an
  expiring share token. Content generated from `log_entries` (stored or regenerated —
  open question). _Phase 4._
- **Log-edit revisions**, **notifications**, and the **mailbox** (`conversations` /
  `conversation_participants` / `messages`) are likewise deferred — see
  [ADR-0009](adr/0009-log-edit-revisions.md) and
  [ADR-0011](adr/0011-notifications-and-messaging.md).

## Web layer (`lib/goodmao2_web/`)

LiveViews under `live/pet_live/`: `Index` (active / past pets), `Form` (new & edit),
`Show` (QuickLog + live timeline), `Access` (sharing/grants), `EndOfCare` (owner-only
lifecycle). Routes live in the `:require_authenticated_user` live_session in `router.ex`.
The `Show` LiveView subscribes to the pet's PubSub topic and streams entries.

### Conventions carried from `baudrate`

- **Accessibility-first:** every meaningful element carries a stable, semantic `id`/`class`
  (loop items derive an id from the record), for tooling, testing, and styling.
- **All user-visible copy through Gettext**, including flash messages and `aria-*`. Enum
  label translations and log summaries live in `Goodmao2Web.Helpers`.
- **`mix precommit`** (compile-warnings-as-errors + unused-deps + format + test) is the gate.
- Tests mirror `lib/` under `test/`; contexts use `DataCase`, LiveViews use `ConnCase`.
