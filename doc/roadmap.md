# GoodMao — Roadmap

_Last updated: 2026-07-20_

## Overview

GoodMao was built **depth-first from the core**: the heart of the product
(effortless structured logging → shareable, authorized timeline) ships first and fully.
This tracks what's done and what's intentionally deferred.

> A **hardening audit** (2026-07-18) reviewed the app across backend/domain, UI/UX/a11y,
> and tooling. It fed the **Near-term hardening**,
> **Engineering & ops maturity**, and **Accessibility & UX polish** sections below, and
> surfaced several rules that are *modeled but not yet enforced* — tracked as hardening,
> not treated as done.

### Vision

The classic vet-visit problem is that owners reconstruct history from memory, badly.
GoodMao makes **effortless structured daily logging** that produces a **shareable health
timeline** — the social/follower layer is not decoration, it is the delivery mechanism for
clinical value.

**One-line pitch:** effortless structured daily logging that produces a shareable health
timeline vets can actually use.

GoodMao is for pets people love, and sometimes grieve. The product should be
**thoughtful, gracious, and affable** throughout — meeting people with warmth, never
rushing a heavy moment, and letting them record the truth of their situation. This is why
end-of-care preserves the record and its date is backdatable ([ADR-0003](adr/0003-pet-lifecycle.md)),
and why error copy stays honest without leaking ([ADR-0007](adr/0007-error-reporting.md)).

## Milestone: v1.0.0

The first public release: the depth-first core (structured logging → shareable, authorized
timeline), the enforcement-gap hardening, and the clinical-timeline, localization,
engineering/ops, and accessibility tranches. Each section below tracks both what shipped and
what was consciously deferred past v1.0.0. Future milestones will be added as sibling chapters.

**Status key:** `[x]` shipped · `[~]` partially shipped · `[ ]` deferred.

### 1. Core principle: structured logging

Free-text ("seemed off today 😟") is clinically useless. The heart of the product is
**structured, one-tap log entries** that a vet can act on. If logging is not effortless,
nobody logs consistently — and inconsistent logs make the vet feature worthless. Free-text
notes exist *alongside* structured fields, never instead of them.

The high-signal, low-effort daily log types carry real clinical domain knowledge — see the
per-type `data` fields in [`architecture.md`](architecture.md):

- Food intake (full / partial / **refused**)
- Water intake (normal / low / high)
- Bathroom (frequency + abnormalities — **urinary blockages in cats are emergencies**, so
  a `bathroom` entry carries an `is_straining` signal)
- Vomiting / diarrhea episodes (count)
- Weight (periodic, in the pet's `weight_unit`)
- Energy / mood (1–5 scale)
- Medication given (timestamped — ties to multi-caretaker coordination)

### 2. Vet access model (both planned)

1. **Time-boxed live access** — an owner grants a vet temporary read access to the pet's
   live timeline for a visit ("share history with Dr. Lin"). The `pet_accesses` grant with
   an `expires_at` already supports this; the vet-facing UI is Phase 4.
2. **Health summary report** — a generated, point-in-time summary the vet reads once (also
   useful for export / print). Deferred — see the deferred entities in
   [`architecture.md`](architecture.md).

Vets are **active, verified users** (professional credential verification), so their input
carries authority rather than being anonymous advice.

### 3. Shipped — MVP core

- [x] Scope-based auth (`phx.gen.auth`), first user → administrator, editable `@handle`
- [x] Administrator site-overview page (`/admin`, `:require_admin`-gated, IDOR-hidden) — a
      read-only oversight surface (user count, admin identity, first-registration gate status);
      the seam future admin features attach to
- [x] Pets: create / list / view / edit, coat colour, weight unit
- [x] Owner-only end-of-care lifecycle (status transition, backdatable `ended_at`, reversible)
- [x] `history_hidden` opt-in flag — schema, changeset, **and** read/write enforcement
      (existence-hidden timeline; see [ADR-0003](adr/0003-pet-lifecycle.md))
- [x] Resource-based per-pet authorization (`owner` / `co_caretaker` / `viewer` / `vet`,
      capability levels, time-boxed grants, ≥1-owner invariant, IDOR-hidden 404s)
- [x] Grant / revoke access by `@handle` or email (Sharing page)
- [x] Structured log entries (single table + `type` + `jsonb`), per-type validation
- [x] One-tap QuickLog (food / water / bathroom / vomit / weight / energy / medication / symptom)
- [x] Backdatable `occurred_at`, free-text note, per-entry `visibility` — owner-only change
      **and** read-side `private` filtering (reads + live PubSub; see
      [ADR-0004](adr/0004-log-visibility.md))
- [x] Vet-authored `vet_note` entries (vet-only)
- [x] Live, type-filterable timeline via Phoenix PubSub — as a chronological list **or** a
      month **calendar view** (per-day counts, urgent/watch cues, day drill-down)
- [x] Soft-delete of entries (`deleted_at`)
- [x] Gettext throughout; `en` populated, `zh_TW` / `ja_JP` scaffolded
- [x] Test suite (context + LiveView) and `mix precommit` gate; dev seed data

### 4. Near-term hardening — enforcement gaps

**Closed (2026-07-18).** The hardening audit found these rules **modeled in the schema
but not enforced in code** — correctness/security defects in shipped areas. All seven are now
enforced at the context boundary, each with a both-directions regression test (the gate
rejects *and* the legitimate case still passes).

- [x] **Enforce `history_hidden`** on every `Logs` read and write — when hidden the timeline
      is existence-hidden (`list_entries` → `[]`, `get_entry` → `nil`, writes → `:unauthorized`,
      reversibly), and `PetLive.Show` shows a notice in place of the QuickLog/timeline
      (`lib/goodmao2/logs.ex`; [ADR-0003](adr/0003-pet-lifecycle.md)).
- [x] **Per-entry `private` visibility on reads** — a caller sees a `private` entry only when
      they are an owner or its recorder; applied in the DB read **and** to live PubSub-pushed
      entries via `Logs.can_view_entry?/3` (`lib/goodmao2/logs.ex`, `PetLive.Show`;
      [ADR-0004](adr/0004-log-visibility.md)).
- [x] **≥1-owner invariant on the grant-update/expiry path** — `grant_access` now guards
      against demoting or time-boxing the last effective owner (`lib/goodmao2/pets.ex`).
- [x] **Recorder-or-owner check on log edit/delete** — owner → any entry; anyone else → only
      what they recorded; `vet_note` edits stay vet-only (`lib/goodmao2/logs.ex`).
- [x] **Site-owner registration gate** — optional `config :goodmao2, :site_owner_email`
      (env `GOODMAO_SITE_OWNER_EMAIL`); when set, only that address may create the first
      (admin) account (`lib/goodmao2/accounts.ex`).
- [x] **Handle-rule parity** — the handle must start with a letter or number (leading `_`
      rejected) and the reserved-word set is expanded (`lib/goodmao2/accounts/user.ex`).
- [x] **Row-locked owner invariant** — owner-grant mutations run in a transaction that takes
      `FOR UPDATE` on the pet's owner rows, so concurrent revokes/demotes can't write-skew into
      an ownerless pet (`lib/goodmao2/pets.ex`).

### 5. Clinical logging & timeline

- [x] Weight trend chart (Phase 1) — an inline, CSP-safe SVG line chart of the pet's weight over
      time on the pet page, with the latest value and its signed change since the first
      measurement (arrow + sign, not colour alone) and an sr-only data table for assistive tech.
      Fed by `Logs.weight_series/3` (visibility- and hidden-history-aware) and live over PubSub
- [ ] Medication schedules + reminders; the "did anyone give the pill?" coordination (Phase 1/3)
- [x] LifeLog media (photos/videos) with active purification ([ADR-0005](adr/0005-media-storage.md);
      Phase 1) — a `life` log can carry JPEG/PNG/GIF/WEBP images and MP4/WEBM video, uploaded
      through the app and **actively purified with ffmpeg** (magic-byte typing; images decoded
      and re-encoded to strip EXIF/GPS; video probed against a codec allow-list + duration cap
      and remuxed). Stored as opaque objects keyed by id under a configured `storage_dir`,
      created atomically with the log, and served only via an authorized, IDOR-hidden
      `GET /media/:id` with `Range` support and hardened headers. Uploads are rate-limited.
      Follow-ups: async (Oban) processing, an orphan-object janitor, share-token media serving
- [x] Log **edit revisions** audit trail + edit-count cap ([ADR-0009](adr/0009-log-edit-revisions.md); Phase 1)
      — each real edit snapshots the prior state into `log_entry_revisions` and bumps a
      denormalized `edit_count`; the 10th edit is refused; a no-op consumes no life; the snapshot
      excludes the share token; the history is readable by any entry-reader (private/hidden-history
      aware) on a dedicated `/pets/:pet_id/logs/:id` page; `type` is immutable on edit
- [x] **Clinical flag chips** (urgent / watch pills) in the timeline — surface the highest-signal
      cues (feline urinary blood/straining, not eating, repeated vomiting, a severe symptom) as
      scannable chips carried by **icon + text + shape, not colour alone** (WCAG 1.4.1). A
      `Helpers.clinical_flags/1` is the single source of truth; the calendar's `clinical_level/1`
      day-cell tint is derived from it, so the two can never disagree
- [x] **One-tap QuickLog buttons** — each common value is its own submit button (Food:
      Ate fully / partially / Refused; Water intake; Urine / Stool; Vomited), logging in a
      single tap via the `quicktap` handler. The full manual form (all fields + note / time /
      visibility) moves into a "More options" disclosure; types needing real input (weight,
      energy, medication, symptom, life) keep the form shown directly

### 6. Sharing, notifications & vet workflow

- [ ] In-site **notification feed** + 1:1 **mailbox**, live unread badges via PubSub
      ([ADR-0011](adr/0011-notifications-and-messaging.md); Phase 3) — preserve: inline vs
      Oban fan-out split, **shared-pet gate** to start a conversation, non-leaking uniform
      refusal, canonical `PairKey`, 2 000-char cap, per-participant read cursor, don't
      self-notify, messages are not bell rows
- [ ] Per-entry **share links** (public token) + anonymous shared timeline/media
      ([ADR-0004](adr/0004-log-visibility.md); Phase 3)
- [ ] Verified **veterinarian accounts** (credential verification) + generated
      **health-summary report** export (Phase 4) — preserve: reject `role: "vet"` unless a
      **verified `VetProfile`** exists, on grant *and* re-grant; the report share token carries
      an **expiry** (unlike log tokens)

### 7. Localization & typography

- [x] **Locale switcher + per-request locale** — `Goodmao2Web.Plugs.Locale` resolves
      cookie → `Accept-Language` → default and `Gettext.put_locale`s it; a LiveView
      `on_mount` mirrors it into live views; `<html lang>` reflects it; a header switcher
      (autonyms `English` / `台灣漢語` / `日本語`) persists the choice via `LocaleController`.
      The **brand wordmark** routes through `brand_name/0` per
      [ADR-0002](adr/0002-culture-first-localization.md) (`GoodMao` / `顧毛` / `グッドマオ`).
- [x] **Trilingual catalogs populated** — every `default` UI string and Ecto `errors`
      message translated for `zh_TW` and `ja_JP`, localized to each culture (ADR-0002), with
      the locale-parity test green.
- [x] **Vendored Roboto Slab + CJK-aware font stack** — Roboto Slab (Apache-2.0, self-hosted
      under `priv/static/fonts/`, within the CSP `font-src 'self'`) is the general alphanumeric
      face for the whole UI (body text and the wordmark); its Latin-only `unicode-range` lets
      CJK fall through to an explicit `PingFang TC` / `Noto Sans TC` / `Hiragino Sans` / …
      chain. The `@font-face` spans the full variable `wght` axis (100–900) so every UI weight
      renders true (`font-display: swap`).
- [x] **Localized the `phx.gen.auth` LiveViews** — log-in / register / confirmation (and the
      session controller's auth flashes) now route every string through `gettext()`, translated
      for `zh_TW` and `ja_JP`; a regression test asserts these pages render in the negotiated
      locale.
- [x] **Readable default size + font-size control** — the base reading size is 20px
      (`html { font-size: 125% }`, scaling the rem-based UI), with a −/+ text-size control
      beside the theme toggle. The choice persists in `localStorage` (clamped 100–175%) and
      is applied before first paint, mirroring the theme-preference mechanism.

### 8. Platform & data model

- [~] **Oban** for background jobs (supersedes the deferred bespoke-job-queue plan, ADR-0006;
      Phase 1/2). The foundation is in (Oban + `Oban.Plugins.Cron`, supervised after the repo),
      and the first workload ships: a daily **token janitor** cron that prunes expired auth
      tokens (`Goodmao2.Accounts.TokenJanitor` → `Accounts.delete_expired_tokens/0`). Still
      deferred until each is needed: reminders, async media, notification fan-out.
- [ ] Weight-unit-aware display + richer `Species` enum (`rabbit` / `bird`); 5-minute
      clock-skew tolerance on the `occurred_at` / `ended_at` future-guard; timeline `offset`
      paging for report views (the `from` / `to` range now backs the shipped calendar view)

### 9. Engineering & ops maturity

Drawn from the hardening audit. Fully shipped over two 2026-07-18 tranches: first CI + dependabot
+ security scanners + `/health` + seed fencing + CHANGELOG, then CSP + `mix goodmao.doctor` +
the locale-parity test + the `a11y-engineering` skill.

- [x] **CI** (`.github/workflows/ci.yml`) — a `mix` job on a `postgres` service, Erlang/Elixir
      pinned from `.tool-versions`, running unused-deps + compile-warnings + format + audit +
      Sobelow + tests.
- [x] **Dependabot** (`.github/dependabot.yml`) — `mix` + `github-actions`, weekly/grouped.
      (`npm` omitted — assets use the esbuild/tailwind installers, no `package.json`.)
- [x] **`mix_audit` + `sobelow`** wired into `mix precommit` and CI.
- [x] **`/health` endpoint + test** — `GET /health` returns `200 ok` when the DB is reachable.
- [x] **Hard-fence `seeds.exs` to `:dev`** — refuses to run outside development.
- [x] **`CHANGELOG.md`** — Keep-a-Changelog, version single-sourced in `mix.exs`.
- [x] **Content-Security-Policy** on the browser pipeline — set per request by
      `Goodmao2Web.Plugs.ContentSecurityPolicy` (a fresh nonce assigned to `@csp_nonce`, stamped
      onto the one inline `<script>` in `root.html.heex`; `default-src 'self'`, `script-src`
      `'self'` + nonce, `style-src 'self' 'unsafe-inline'`, `connect-src 'self'` for the LiveView
      socket, `img-src 'self' data:` for the inline favicon). Sobelow's static check only sees a
      CSP declared via `put_secure_browser_headers`, so `.sobelow-conf` still ignores `Config.CSP`
      as a documented blind spot, not a missing header.
- [x] **`mix goodmao.doctor` preflight task** — checks Erlang/Elixir vs `.tool-versions`, Postgres
      reachability + the `CREATEDB` privilege, deps fetched, asset installers, and (under
      `MIX_ENV=prod`) required secrets; PASS/WARN/FAIL per line, non-zero exit only on a hard FAIL
      (`lib/mix/tasks/goodmao.doctor.ex`). A single `doctor` verb (`mix` is the entry point).
- [x] **Locale-parity test** across `en` / `zh_TW` / `ja_JP` (`test/goodmao2/locale_parity_test.exs`)
      — asserts *structural* parity: identical domain and msgid sets across locales, no `#, fuzzy`
      entries, and `.pot` templates fully merged. (Translation *completeness* stays deferred with the
      locale switcher below; the scaffolded catalogs are intentionally untranslated.)
- [x] The **`a11y-engineering` skill** (`.claude/skills/a11y-engineering/SKILL.md`) —
      written for HEEx/LiveView + daisyUI/Tailwind + Gettext. Formalizes the accessibility-first
      invariant `AGENTS.md` states; completes the project's seven-skill set.
- [ ] **Co-hosting deployment note** — GoodMao shares its default HTTP port (`PORT`, default
      `4000`) and dev ports (`4000`/`4001` http/https, `4002` test) with sibling Phoenix apps such
      as Baudrate, so the two collide if run at their defaults on one host. In production the
      listening port is `PORT`-driven, so co-hosting is just: give each app a distinct `PORT`, a
      distinct Postgres role/database, and front both with one reverse proxy terminating TLS on
      `443` and routing by hostname (the `443` in `runtime.exs` is only the canonical-URL host, not
      a listener). To document as a deploy runbook.
- [ ] **Ansible-driven deployment** — provisioning and releases will be automated with Ansible,
      mirroring Baudrate's approach (see `my_ansible_playbooks`), so the two apps co-host under a
      consistent, repeatable playbook (distinct `PORT` / Postgres role+db per app, shared reverse
      proxy). Playbook not yet written.

### 10. Accessibility & UX polish

Delivered 2026-07-18 as one tranche — small CSS/HEEx edits in `assets/css/app.css`,
`components/layouts.ex`, `components/layouts/root.html.heex`, `components/core_components.ex`,
and a `PointerGlow` hook in `assets/js/app.js`.

- [x] **Skip-to-content link** → `#main-content` (`tabindex="-1"`), visually hidden until focused
      (`.gm-skip-link`, WCAG 2.4.1 bypass block).
- [x] **`:focus-visible` brand ring** (2 px + 2 px offset, `var(--color-primary)`) on every
      focusable element — backs the a11y invariant `AGENTS.md` states.
- [x] **`aria-hidden` on decorative `<.icon>` glyphs** — the shared `<.icon>` now hides the glyph
      by default with an `aria_hidden={false}` opt-out for standalone icons; the icon-only theme
      toggle buttons gained `aria-label`s so they stay named.
- [x] **Global `prefers-reduced-motion` guard** — neutralises transitions/animations and the
      micro-interactions/glow below (keeps the focus ring, which isn't motion).
- [x] **Fluent design tokens** — layered elevation shadow ramp (`--gm-elevation-1..3`, deepened in
      dark), decelerating curve + durations, and opt-in `.gm-lift` (card hover-lift) / `.gm-press`
      (button press-depth) utilities.
- [x] **`theme-color` meta + inline SVG favicon + branded `<.live_title>`** — the title suffix now
      reads "· GoodMao"; light/dark `theme-color`s match the base canvas.
- [x] **Footer + sticky app-shell** — `#app-shell` flex column with a sticky, backdrop-blurred
      header and a `#site-footer` (the natural home for the future locale switcher).
- [x] **Reveal pointer-glow** — the `PointerGlow` LiveView hook + `.gm-glow` surface; the hook
      never attaches its listener under `prefers-reduced-motion`.

**Explicitly out of scope** (antithetical to a LiveView monolith): PWA / service worker /
offline; no-JS progressive-enhancement form fallbacks. Phoenix hero-icons already satisfy
[ADR-0010's](adr/README.md) self-hosted/SSR-safe/tree-shaken requirements, so no separate
icon vendoring is needed. GoodMao ships a light/dark/system theme toggle.

### 11. Notes / follow-ups

- User references that are audit-only (`recorded_by_user_id`, `granted_by_user_id`,
  `created_by_user_id`) are stored without FK navigations, a deliberate
  cascade-path decision.
- The `life` log type ships as a **text-only** daily-life note (authored from QuickLog,
  caption required); only its photo/video enrichment is deferred with the media work above.
  The `visibility` `public` + share-token concept is modeled in the schema but its
  UI/endpoints are deferred with the share-link work above.
