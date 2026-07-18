# GoodMao2 — Roadmap

_Last updated: 2026-07-18_

The Phoenix edition was built **depth-first from the core**: the heart of the product
(effortless structured logging → shareable, authorized timeline) ships first and fully.
This tracks what's done and what's intentionally deferred. Feature framing follows the
original [GoodMao roadmap](../../GoodMao/doc/roadmap.md).

> A **GoodMao parity audit** (2026-07-18) compared this port against the mature original
> across backend/domain, UI/UX/a11y, and tooling. It fed the **Near-term hardening**,
> **Engineering & ops maturity**, and **Accessibility & UX polish** sections below, and
> surfaced several rules that are *modeled but not yet enforced* — tracked as hardening,
> not treated as done.

## Vision

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

## Core principle: structured logging

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

## Vet access model (both planned)

1. **Time-boxed live access** — an owner grants a vet temporary read access to the pet's
   live timeline for a visit ("share history with Dr. Lin"). The `pet_accesses` grant with
   an `expires_at` already supports this; the vet-facing UI is Phase 4.
2. **Health summary report** — a generated, point-in-time summary the vet reads once (also
   useful for export / print). Deferred — see the deferred entities in
   [`architecture.md`](architecture.md).

Vets are **active, verified users** (professional credential verification), so their input
carries authority rather than being anonymous advice.

## Shipped — MVP core

- [x] Scope-based auth (`phx.gen.auth`), first user → administrator, editable `@handle`
- [x] Pets: create / list / view / edit, coat colour, weight unit
- [x] Owner-only end-of-care lifecycle (status transition, backdatable `ended_at`, reversible)
- [x] `history_hidden` opt-in flag (schema + changeset) — ⚠ *read/write enforcement is
      not wired yet; tracked under [Near-term hardening](#near-term-hardening--enforcement-gaps)*
- [x] Resource-based per-pet authorization (`owner` / `co_caretaker` / `viewer` / `vet`,
      capability levels, time-boxed grants, ≥1-owner invariant, IDOR-hidden 404s)
- [x] Grant / revoke access by `@handle` or email (Sharing page)
- [x] Structured log entries (single table + `type` + `jsonb`), per-type validation
- [x] One-tap QuickLog (food / water / bathroom / vomit / weight / energy / medication / symptom)
- [x] Backdatable `occurred_at`, free-text note, per-entry `visibility` (owner-only change)
      — ⚠ *the owner-only **change** is shipped; **read-side** `private` filtering is not
      wired yet; tracked under [Near-term hardening](#near-term-hardening--enforcement-gaps)*
- [x] Vet-authored `vet_note` entries (vet-only)
- [x] Live, type-filterable timeline via Phoenix PubSub
- [x] Soft-delete of entries (`deleted_at`)
- [x] Gettext throughout; `en` populated, `zh_TW` / `ja_JP` scaffolded
- [x] Test suite (context + LiveView) and `mix precommit` gate; dev seed data

## Near-term hardening — enforcement gaps

Highest priority. The GoodMao parity audit found these rules **modeled in the schema but
not enforced in code** — the columns and write-guards exist, but the matching read-filter
or invalidation is missing. They are correctness/security defects in shipped areas, not new
features. Each should land with a **both-directions regression test** (the gate rejects
*and* the legitimate case still passes), matching the discipline in `pets_test.exs` /
`logs_test.exs`.

- [ ] **Enforce `history_hidden`** on every `Logs` read and write — `list_entries`,
      `get_entry`, and the create/update/delete paths never consult it (`lib/goodmao2/logs.ex`),
      so a documented privacy control currently does nothing. When hidden, the timeline is
      existence-hidden (empty / `nil` / unauthorized), reversibly ([ADR-0003](adr/0003-pet-lifecycle.md)).
- [ ] **Apply per-entry `private` visibility on reads** — `list_entries`/`get_entry` do no
      visibility filtering (`lib/goodmao2/logs.ex`), so viewers/co-caretakers/vets can see
      entries an owner marked `private`. Rule: a caller sees an entry when
      `visibility != "private" OR recorded_by_user_id == caller OR role == owner`. Requires
      threading the caller (role + id) into these reads and `PetLive.Show`
      ([ADR-0004](adr/0004-log-visibility.md)).
- [ ] **≥1-owner invariant on the grant-update/expiry path** — `grant_access` doubles as the
      update path (`insert_or_update`) and never calls `guard_last_owner` (`lib/goodmao2/pets.ex`),
      so a sole owner can downgrade themselves to `viewer` or set an `expires_at` and leave the
      pet ownerless. Guard whenever an existing `owner` grant is changed to non-owner or given
      an expiry.
- [ ] **Recorder-or-owner check on log edit/delete** — `update_entry`/`delete_entry` check only
      `:write` (`lib/goodmao2/logs.ex`), so any co-caretaker can alter another caretaker's
      entries. Matrix: owner → any general log; recorder → own logs; `vet_note` → authoring vet
      only (authoring is already gated; edit/delete is not).
- [ ] **Site-owner registration gate** for the bootstrap admin — `register_user` grants
      `is_admin` to the first registrant with no gate (`lib/goodmao2/accounts.ex`), so on a
      fresh public deploy anyone can grab admin. Add optional `config :goodmao2, :site_owner_email`;
      when set, only that email may create the first account.
- [ ] **Handle-rule parity** — the regex `~r/^[^.].*[^.]$/` forbids only leading/trailing dots,
      so `@_johndoe` passes here but not in GoodMao (`lib/goodmao2/accounts/user.ex`). Require the
      first char to be alphanumeric and expand `@reserved_handles` toward GoodMao's ~40-word set.
- [ ] **Row-lock the owner invariant** — `guard_last_owner` is a lock-free `Repo.aggregate`
      (`lib/goodmao2/pets.ex`); two concurrent revokes can write-skew into an ownerless pet.
      Wrap owner-mutations in a transaction with `lock: "FOR UPDATE"` on the pet's owner rows.

## Deferred (mapped to the original's later phases)

- [ ] Weight / trend charts (Phase 1)
- [ ] Medication schedules + reminders; the "did anyone give the pill?" coordination (Phase 1/3)
- [ ] LifeLog media (photos/videos) with EXIF-stripping purification — the `image` lib +
      `life` type is scaffolded ([ADR-0005](adr/0005-media-storage.md); Phase 1)
- [ ] **Oban** for background jobs (janitor, reminders, async media, notification fan-out)
      — deferred until a job actually needs it (supersedes the original's ADR-0006; Phase 1/2)
- [ ] Log **edit revisions** audit trail + edit-count cap ([ADR-0009](adr/0009-log-edit-revisions.md); Phase 1)
      — preserve: 9-edit cap (refuse the 10th), only a *real* change consumes a life, snapshot
      **excludes the share token**, readable by any entry-reader, survives soft-delete, type
      immutable on edit
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
- [ ] Weight-unit-aware display + richer `Species` enum (`rabbit` / `bird`); 5-minute
      clock-skew tolerance on the `occurred_at` / `ended_at` future-guard; timeline
      `from` / `to` / `offset` query params for the calendar/report views
- [ ] **Locale switcher + per-request locale**: resolve cookie → `Accept-Language` → default,
      call `Gettext.put_locale` in a plug + LiveView `on_mount`, reflect `lang` on `<html>`
      (today hard-coded `en`), and route the **brand wordmark** through Gettext per
      [ADR-0002](adr/0002-culture-first-localization.md) (autonym menu labels:
      `English` / `台灣漢語` / `日本語`). This unlocks the already-maintained `zh_TW` / `ja_JP`
      catalogs, which are currently unreachable by users (Phase 1)
- [ ] **Trilingual translations populated** for `zh_TW` / `ja_JP`, and full localization of the
      `phx.gen.auth` LiveViews (login/register/settings still carry generator-default English)
- [ ] **Vendored Roboto Slab + CJK-aware font stack** — a brand slab-serif for Latin/numeric
      text with an explicit `PingFang TC` / `Noto Sans TC` / `Hiragino Sans` / … fallback chain,
      so a trilingual app renders Traditional-Chinese/Japanese correctly instead of leaving it to
      browser defaults (`unicode-range` + `font-display: swap`)
- [ ] **Clinical flag chips** (urgent / watch pills) in the timeline — surface the highest-signal
      cues (feline urinary blood/straining, anorexia, repeated vomiting) as scannable chips
      carried by **icon + text + shape, not colour alone** (WCAG 1.4.1); add a `clinical_flags/1`
      helper rather than burying them in the summary string
- [ ] **One-tap QuickLog buttons** — make each common value its own submit button (Food:
      Full / Partial / Refused), advanced context in a disclosure, instead of the current
      tab-then-fill flow (fewer taps for the common case)

## Engineering & ops maturity

Drawn from the parity audit — GoodMao2 has **no `.github/` at all** (no CI, no dependabot),
which is the single biggest maturity gap.

- [ ] **CI** (`.github/workflows/ci.yml`) — a `mix` job: `erlef/setup-beam` pinned from
      `.tool-versions`, a `postgres` service matching `config/test.exs`, deps cache, then the
      existing `precommit` chain (`compile --warnings-as-errors` + `format --check-formatted` +
      `test`). Nothing verifies pushes/PRs today.
- [ ] **Dependabot** (`.github/dependabot.yml`) — `mix` + `github-actions` (+ `npm` in `/assets`
      if present), weekly/grouped; pairs with the `check-updates` skill.
- [ ] **`mix_audit`** (+ optional **`sobelow`**) wired into CI / the `precommit` gate — Elixir-native
      continuous security signal complementing the on-demand `security-audit` skill.
- [ ] **`/health` endpoint + test** — an anonymous route running a trivial `Repo` query; the
      day-one hook every later deploy/monitoring practice hangs off.
- [ ] **`mix doctor` preflight task** — check Erlang/Elixir vs `.tool-versions`, Postgres + the
      `goodmao2` CREATEDB role, deps, asset installers, prod secrets. Port only the `doctor` verb
      (not GoodMao's whole `./goodmao` CLI — `mix` is already the entry point).
- [ ] **Locale-parity test** across `en` / `zh_TW` / `ja_JP` — the one stated invariant with no
      test behind it (fail the build on a missing/fuzzy translation).
- [ ] **Hard-fence `seeds.exs` to `:dev`** — it plants `password1234!` demo accounts with no
      environment guard; make seeding structurally unable to run outside development.
- [ ] **`CHANGELOG.md`** — completes the already-wired `release-engineering` skill (version stays
      single-sourced in `mix.exs`).
- [ ] Port the **`a11y-engineering` skill** — the only one of GoodMao's seven Claude skills
      GoodMao2 lacks; rewrite for HEEx/LiveView + daisyUI/Tailwind + Gettext. Formalizes the
      accessibility-first invariant `AGENTS.md` already states.

## Accessibility & UX polish

Mostly small CSS/HEEx edits in `assets/css/app.css`, `components/layouts.ex`, and
`components/core_components.ex` — cluster the cheap a11y wins together.

- [ ] **Skip-to-content link** → `#main-content` (`tabindex="-1"`), visually hidden until focused
      (WCAG 2.4.1 bypass block).
- [ ] **`:focus-visible` brand ring** (2 px + 2 px offset, `var(--color-primary)`) — the a11y
      invariant `AGENTS.md` claims but doesn't currently back in CSS.
- [ ] **`aria-hidden` on decorative `<.icon>` glyphs** — the shared `<.icon>` renders no
      `aria-hidden` today; add it (with an opt-out for standalone icons) so screen readers don't
      announce decorative glyphs.
- [ ] **Global `prefers-reduced-motion` guard** — ship alongside any motion added below.
- [ ] **Fluent design tokens** — layered elevation shadow ramp, decelerating motion curve,
      card hover-lift, button press-depth (the "delightful micro-interactions" `AGENTS.md` asks
      for), as CSS custom properties.
- [ ] **`theme-color` meta + SVG favicon + branded `<.live_title>`** (the title suffix still reads
      "· Phoenix Framework").
- [ ] **Footer + sticky app-shell** — the natural home for the locale switcher.
- [ ] **Reveal pointer-glow** (a LiveView JS hook that self-disables under
      `prefers-reduced-motion`) — pure delight; do it last.

**Explicitly not porting** (tied to the SvelteKit/PWA architecture, antithetical to a LiveView
monolith): PWA / service worker / offline; no-JS progressive-enhancement form fallbacks;
SvelteKit routing/preload; re-vendoring Lucide icons (Phoenix hero-icons already satisfy
[ADR-0010's](adr/README.md) self-hosted/SSR-safe/tree-shaken requirements). Note GoodMao2's
light/dark/system theme toggle is **ahead** of GoodMao, which has no dark theme.

## Notes / follow-ups

- User references that are audit-only (`recorded_by_user_id`, `granted_by_user_id`,
  `created_by_user_id`) are stored without FK navigations, mirroring the original's
  cascade-path decision.
- The `life` log type and `visibility` `public` + share-token concept are modeled in the
  schema but their UI/endpoints are deferred with the media and share-link work above.
