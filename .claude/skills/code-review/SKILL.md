---
name: code-review
description: Perform a project-wide full-scope code review of GoodMao covering correctness, security (resource-based authorization), test coverage, locale sync, documentation quality, code smells, and UI/UX accessibility, then report findings and fix critical issues.
---

When performing a code review, conduct a **full project-wide sweep** — do not limit scope
to recent changes. Read broadly across the codebase and apply every check below.

---

## Step 1 — Orient and Plan

Before reviewing, understand the system's current shape:
- Read `CLAUDE.md`, `AGENTS.md` (GoodMao section), and `doc/architecture.md` for
  architecture, conventions, and the invariants to preserve.
- Skim `lib/goodmao2/` (contexts: `Accounts`, `Pets`, `Logs`) and
  `lib/goodmao2_web/live/` (LiveViews).
- Check `doc/roadmap.md` for what's intentionally deferred (don't file deferred features
  as findings).
- Prioritise the **authorization boundary** (`Pets`), then log write paths, then auth.

---

## Step 2 — Correctness

- Logic errors, incorrect pattern matches, missing `nil`/`{:error, _}` guards.
- **Ecto**: missing `Repo.preload` for associations touched in templates (e.g. an access
  grant's `user`), N+1 risks, use of `Ecto.Multi`/transactions where invariants must hold
  atomically (pet creation + owner grant is one such transaction).
- **LiveView**: every LiveView that subscribes to PubSub or is reachable while receiving
  messages MUST end `handle_info/2` with a catch-all `def handle_info(_msg, socket), do:
  {:noreply, socket}` (`PetLive.Show` subscribes to the pet timeline). Watch for stale
  socket assigns after `push_navigate`, and races between `mount` and `handle_params`.
- **Streams**: collections use `stream/3` with `phx-update="stream"` and a parent DOM id;
  filtering re-streams with `reset: true`; counts/empty-states are tracked with a separate
  assign or the `only:` CSS trick (streams are not enumerable/countable).
- **Soft-delete**: `log_entries` use `deleted_at`; every read must filter
  `is_nil(deleted_at)`. Deletion stamps the column, never `Repo.delete`.
- **Lifecycle**: end-of-care is a status transition (`lifecycle_status` + `ended_at`), never
  a deletion; list queries separate active vs. ended pets correctly.
- **Rust NIFs** (`native/goodmao2_native`, loaded by `Goodmao2.Native`): a NIF must not block
  the BEAM scheduler — long-running or blocking work uses a dirty scheduler
  (`#[rustler::nif(schedule = "DirtyCpu"/"DirtyIo")]`). It must return `Result`/error terms
  rather than panic (`unwrap`/`expect`/out-of-bounds unwind into a node crash), and validate
  sizes/lengths of decoded terms before allocating or indexing. The `rustler` crate version
  stays in lockstep with the Elixir `:rustler` dep; `Cargo.lock` is committed, the built `.so`
  is not. `mix compile` builds the crate — a Rust error fails the Elixir build.

---

## Step 3 — Security (authorization is the core)

GoodMao holds **sensitive health data**. The security boundary is **resource-based
per-pet authorization** in `Goodmao2.Pets`. Audit it hard:

- **Every LiveView mount that touches a pet** resolves it via `Pets.fetch_pet(user, id,
  require: level)` and redirects on `{:error, :not_found}` — never loads a pet by raw id
  without an access check. Inaccessible pets return **not-found, never "forbidden"** (IDOR-hidden).
- **Capability is re-checked at the context boundary**, not only in the LiveView: `Logs`
  write functions call `Pets.can?/3`; `vet_note` authoring is vet-only; changing a log's
  `visibility` is owner-only. Mount-time checks alone are insufficient.
- **Owner invariant**: creating a pet inserts the creator's `owner` grant in the same
  transaction; revoking/expiring the last effective owner is refused (`:last_owner`).
- **No admin backdoor**: `is_admin` is a global role that must NOT grant access to pet data
  — verify no query bypasses `PetAccess` for admins.
- **Effective-grant logic**: `status == "active"` AND (`expires_at` nil OR future) is applied
  consistently in `list_pets`, `effective_access`, and `list_accesses`.
- **Injection / output encoding**: no `String.to_atom/1` on user input; no user input in
  file paths; all Ecto queries parameterized (no interpolation into `fragment()`); all
  dynamic HEEx values rendered with `{@var}` (auto-escaped) — audit any `raw/1`.
- **HTTP client** is `Req` only (flag any HTTPoison/Tesla/httpc).
- **Auth/session**: `/users/settings` and other sensitive actions sit behind
  `:require_sudo_mode`; the router's `live_session`/pipeline scoping is correct; magic-link
  and password-reset tokens are single-use/expiring (generated code — verify it's unchanged).
- **Second factor (ADR-0013)**: no primary-auth path issues a session token without going
  through `login_next_step/1` (the pending-2FA stage gates magic-link *and* password); the
  `:two_factor` LiveViews use the `:require_pending_2fa` on_mount (never `:require_authenticated`);
  the completion controller re-verifies each factor server-side and locks out after repeated
  failures; TOTP secrets are encrypted and recovery codes hashed (never logged); security-key
  credentials are hard-deleted; an admin can't remove their last factor.
- Cross-check the **OWASP Top 10**, with A01 (Broken Access Control) and A03 (Injection) as
  the highest-yield categories here.

For a dedicated deep pass, use the `security-audit` skill.

---

## Step 4 — Test Coverage

- Every public context function and LiveView action has a test in `test/` mirroring `lib/`.
- Context tests use `Goodmao2.DataCase`; LiveView/controller tests use `Goodmao2Web.ConnCase`
  (with `setup :register_and_log_in_user`). Pet/log data comes from `Goodmao2.PetsFixtures`.
- **Authorization has negative-path tests**: stranger → not-found, viewer cannot write,
  non-owner cannot manage/grant, last-owner revoke refused, expired/revoked grant denies.
- No `Process.sleep` for timestamp ordering — set explicit `occurred_at`/timestamps instead.
- Queries with user-visible ordering include a deterministic tiebreaker (e.g. `desc: :id`).
- Tests are `async: true` where they don't share mutable global state, and pass reliably.

---

## Step 5 — Locale Sync

- Every user-visible string is wrapped in `gettext()` — no bare English in templates, flash
  messages, or HTML attributes (`title`, `aria-label`, `placeholder`). Enum-label
  translations and log summaries live in `Goodmao2Web.Helpers`.
- `%{var}` interpolation is used inside `gettext()` — never Elixir string interpolation.
- After changing strings, `mix gettext.extract && mix gettext.merge priv/gettext` is run so
  `default.pot` and the `en` / `zh_TW` / `ja_JP` `.po` files stay in sync; no orphaned `msgid`s.
- (zh_TW/ja_JP translations are a deferred follow-up — an empty `msgstr` falling back to
  English is expected, not a finding; a *missing msgid* is.)

---

## Step 6 — Documentation Quality

- `@moduledoc` present and accurate for every context and schema; `@doc` on public functions
  with non-obvious behaviour (the authorization functions especially).
- `README.md`, `CLAUDE.md`, `AGENTS.md` (GoodMao section), `doc/architecture.md`, and
  `doc/roadmap.md` match the current code (contexts, schema, authorization table, deferred list).
- No commented-out dead code in place of proper documentation.

---

## Step 7 — Code Smells

- **Duplication** that should be a shared helper/context function; **bloated functions** and
  tangled `with` chains that should be named steps.
- **Primitive obsession**: raw strings where a named enum/constant is clearer (the role,
  status, type, visibility value lists live on the schemas — reuse them).
- **Feature envy**: a LiveView reaching into another context's internals instead of its
  public API — all pet reads/writes go through `Pets`/`Logs`.
- **Stale code**: unused functions, dead branches, leftover `IO.inspect`/`dbg`.
- **One module per file** — never nest modules in a single file.

---

## Step 8 — UI/UX and Accessibility (a11y)

This is a first-class project convention (see `AGENTS.md`), and the tests depend on it.

- **Every meaningful element carries a stable, semantic `id`/`class`** (page/section-prefixed
  kebab-case); loop items derive a dynamic id from the record (`id={"revoke-#{access.id}"}`)
  plus a shared class. Skip only presentational wrappers and `<.icon>`.
- **Semantic HTML**: `<section aria-labelledby>` for headed areas, `<article>` for list items,
  `<nav aria-label>` for navigation.
- **WAI-ARIA**: icon-only buttons/links have `aria-label`; form fields have labels (use the
  imported `<.input>`); dynamic regions use `aria-live` where appropriate.
- **Layout**: LiveView templates begin with `<Layouts.app flash={@flash}
  current_scope={@current_scope}>`; `<.flash_group>` is only called inside `layouts.ex`.
- **Colour/contrast** ≥ WCAG 2.1 AA; information not conveyed by colour alone (the
  ⚠ straining/emergency cue is paired with text).
- Custom CSS in `assets/css/app.css` hooks onto the semantic `id`/`class` selectors, not
  fragile structural/positional selectors.

---

## Reporting

Present all findings grouped by severity:

| Severity | Criteria |
|----------|----------|
| **Critical** | Auth bypass / IDOR on pet data, data loss, injection, secret exposure — fix immediately |
| **Major** | Logic errors, missing test coverage for observable behaviour, broken conventions causing runtime failures, a11y barriers blocking screen-reader/keyboard users |
| **Minor** | Style, clarity, missing docs, i18n gaps, cosmetic a11y issues, minor smells |

For each finding: cite the **file and line number**, describe the issue, explain the impact,
and provide a **concrete fix**.

---

## Fixing

After reporting, **apply fixes for all Critical and Major findings directly**, then run the
gate:

```bash
mix precommit
```

Do not consider the review complete until it passes. When a bug class is found once, **sweep
the whole project for other instances of the same class** before finishing.
