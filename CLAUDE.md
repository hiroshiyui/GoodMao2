# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read these first

- **`AGENTS.md`** — the authoritative Elixir/Phoenix/LiveView/Ecto coding rules for this
  repo, plus a **GoodMao2 section** stating the invariants to preserve (authorization
  boundary, one-table logs, soft-delete, a11y, Gettext). Follow it.
- **`doc/architecture.md`** — contexts, data model (incl. per-`type` log payload fields),
  authorization table, deferred entities, and the GoodMao → GoodMao2 technology mapping.
- **`doc/roadmap.md`** — the product vision, the structured-logging core principle, and
  what's shipped vs. intentionally deferred.
- **`doc/glossary.md`** — the shared product/domain vocabulary (and its Phoenix tech terms).
- **`doc/adr/`** — Architecture Decision Records: the *why* behind the invariants
  (pet-lifecycle, log-visibility, error-reporting, soft-delete, localization, deferred
  media/revisions/notifications). Ported from GoodMao and adapted to this stack.
- **`doc/web-application-development-common-practices.md`** — product-agnostic engineering
  lessons (security/data-modeling/testing/ops), each with the failure mode behind it.

## Commands

```bash
mix setup                      # deps + create/migrate DB + seed demo data + build assets
mix phx.server                 # dev server at http://localhost:4000 (mailbox: /dev/mailbox)
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

Postgres: dev and test both use a **`goodmao2`** role (password `goodmao2`) needing
`CREATEDB` — see `config/dev.exs` / `config/test.exs`. Demo logins after seeding:
`owner@example.com` / `vet@example.com`, both password `password1234!`.

## Architecture in one screen

GoodMao2 is a **single Phoenix/LiveView monolith** (no separate API/frontend). Domain
logic lives in three contexts under `lib/goodmao2/`; the web layer is thin LiveViews that
call them.

- **`Accounts`** (`accounts.ex`) — `phx.gen.auth` scope-based auth (the caller is
  `socket.assigns.current_scope.user`), extended with a public `@handle`, `display_name`,
  and `is_admin` (the **first registered user** becomes the sole administrator). Admin is a
  global role only; it grants **no access to pet data**.
- **`Pets`** (`pets.ex`) — pets, `pet_accesses` grants, and the **resource-based
  authorization core**. This is the security-critical module:
  - Authorization is *computed per request* from an **effective grant** (`status=active`
    AND not expired), never global. Roles: `owner` / `co_caretaker` / `viewer` / `vet`;
    capability levels: `:read` / `:write` / `:manage`.
  - `Pets.can?(pet, user, level)` and `Pets.fetch_pet(user, id, require: level)` — the
    latter returns `{:error, :not_found}` for inaccessible pets (**IDOR-hidden**, never
    "forbidden").
  - Creating a pet inserts the creator's `owner` grant in the **same transaction**; the
    **≥1-owner invariant** is enforced on revoke (`{:error, :last_owner}`).
- **`Logs`** (`logs.ex`) — structured entries + the timeline + **PubSub**. All entry types
  share **one `log_entries` table** with a `type` discriminator and a `jsonb` `data`
  payload; per-type field validation is in `LogEntry.changeset/2`. Entries are
  **soft-deleted** (`deleted_at`); every read filters `deleted_at IS NULL`. Writes re-check
  `Pets` capability at the context boundary (`vet_note` is vet-only; changing `visibility`
  is owner-only). `create/update/delete_entry` broadcast on the pet's topic so
  `PetLive.Show` streams live updates.

Web LiveViews (`lib/goodmao2_web/live/pet_live/`): `Index`, `Form` (new/edit), `Show`
(QuickLog + live filterable timeline), `Access` (grant/revoke), `EndOfCare` (owner-only
lifecycle). They authorize in `mount` via `Pets.fetch_pet/3` and `push_navigate` on
failure. Routes are in the `:require_authenticated_user` `live_session` in `router.ex`.
Shared view helpers (enum-label translations, log summaries) are in
`lib/goodmao2_web/helpers.ex`, imported app-wide via `goodmao2_web.ex`.

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
- Tests mirror `lib/` under `test/`: `use Goodmao2.DataCase` for contexts, `use
  Goodmao2Web.ConnCase` (+ `setup :register_and_log_in_user`) for LiveViews. Pet/log test
  data comes from `Goodmao2.PetsFixtures`.
