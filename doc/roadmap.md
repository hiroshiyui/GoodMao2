# GoodMao — Roadmap

_Last updated: 2026-07-23_

## Overview

GoodMao was built **depth-first from the core**: the heart of the product
(effortless structured logging → shareable, authorized timeline) ships first and fully.
This tracks what's done and what's intentionally deferred.

**[Milestone v1.0.0](#milestone-v100) shipped on 2026-07-23** and is live at
[goodmao.tw](https://goodmao.tw); every item in that chapter is `[x]`.
**[Milestone v1.1.0](#milestone-v110)** gathers what was deferred past it — coordination
polish, per-pet timezones, the media/sharing tail, and the operational items a live
deployment created.

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
engineering/ops, and accessibility tranches. **Released 2026-07-23**; every item below is
shipped, and what was consciously deferred past it now lives in
[Milestone v1.1.0](#milestone-v110).

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

### 2. Vet access model (both shipped)

1. **Time-boxed live access** — an owner grants a vet temporary read access to the pet's
   live timeline for a visit ("share history with Dr. Lin"). The `pet_accesses` grant with an
   `expires_at` backs it; the `vet` role is granted only to a **verified `VetProfile`**
   (credential submission → admin review on `/admin`), enforced on grant *and* re-grant
   ([ADR-0012](adr/0012-vet-access-model.md)).
2. **Health summary report** — a generated, point-in-time summary a vet reads once (also
   useful for export / print). A **frozen snapshot** over a date range, viewable/printable by
   any effective grant and shareable through an **expiring anonymous link**; private entries
   are never included. See [ADR-0012](adr/0012-vet-access-model.md).

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
      time on the pet page, aggregated to one **daily-average** point per *local* day and
      partitioned strictly by calendar day (faint x/y scale lines; per-day dots dropped past ~45
      days; the sr-only data table evenly sampled for long histories). Shows the latest value and
      its signed change since the first day (arrow + sign, not colour alone); clicking a point
      reveals its date and weight (`WeightChart` hook, with a native `<title>` hover fallback in the
      static report). Fed by `Logs.weight_series/3` (visibility- and hidden-history-aware) and live
      over PubSub
- [x] **Medication schedules + reminders** — the "did anyone give the pill?" coordination
      ([ADR-0019](adr/0019-medication-schedules-and-reminders.md)). Recurring schedules (each with
      its own timezone) materialize durable **dose slots**; any `:write` caretaker marks a slot
      **Given** (an atomic claim that writes a normal `medication` timeline entry) or **Skipped**,
      and everyone sees who handled it, live. An Oban cron (`ReminderWorker`, `*/15`) fills the
      dose horizon, ages overdue slots to `missed`, and fans out a de-duped `medication_due` bell +
      Web Push to effective `:write` caretakers. UI: `PetLive.Medications`. Follow-ups in [v1.1.0](#milestone-v110): snooze /
      escalation, per-pet timezones, dose-history retention GC
- [x] LifeLog media (photos/videos) with active purification ([ADR-0005](adr/0005-media-storage.md);
      Phase 1) — a `life` log can carry JPEG/PNG/GIF/WEBP images and MP4/WEBM video, uploaded
      through the app and **actively purified with ffmpeg** (magic-byte typing; images decoded
      and re-encoded to strip EXIF/GPS; video probed against a codec allow-list + duration cap
      and remuxed). Stored as opaque objects keyed by id under a configured `storage_dir`,
      created atomically with the log, and served only via an authorized, IDOR-hidden
      `GET /media/:id` with `Range` support and hardened headers. Uploads are rate-limited.
      Purification runs **off the request path** (`Media.PurifyWorker`, Oban): the upload is
      staged and the entry appears immediately, then each file is purified + attached in the
      background (live via PubSub; a failure sends the uploader a `media_failed` bell). A daily
      `Media.OrphanJanitor` reclaims stray objects + stale staged uploads, and share-token media
      serving shipped with per-entry share links (ADR-0004). Follow-up in [v1.1.0](#milestone-v110): attach media to an
      existing entry
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

- [x] In-site **notification feed** + 1:1 **mailbox**, live unread badges via PubSub
      ([ADR-0011](adr/0011-notifications-and-messaging.md); Phase 3, Stage 1) — a bell feed
      (`Goodmao2.Notifications`) and a private mailbox (`Goodmao2.Messaging`), each with its
      own live badge kept fresh over PubSub through a global `Goodmao2Web.UnreadBadges`
      `on_mount` hook. Preserves every invariant: the **shared-pet gate** to start a
      conversation, a **non-leaking uniform** `:cannot_message` refusal, a canonical unordered
      **user-pair** key (DB `CHECK` + unique index), the 2 000-codepoint cap, a per-participant
      **read cursor**, don't self-notify, and messages are **not** bell rows. Single-recipient
      grant/revoke notify **inline** from `Pets`; `log_added` (visibility-aware) and admin
      **announcements** fan out via **Oban** (`Log`/`AnnouncementFanoutWorker`).
- [x] **Web Push** ([ADR-0011](adr/0011-notifications-and-messaging.md) Stage 2) — OS-level push
      of the same bell events. An `SSRF-safe`, DNS-pinned outbound client; RFC 8291/8188/8292
      crypto hand-rolled on `:crypto` (no external lib); an Oban `PushDispatchWorker` hooked at the
      single `Notifications.create/3` choke point; a service worker + opt-in on `/users/settings`.
      **VAPID keys are admin-generated in the Web UI** (`/admin/settings`), the private key encrypted
      at rest. New **mailbox messages** push too (`Messaging.MessagePushWorker`). Follow-up in [v1.1.0](#milestone-v110):
      notification batching/digest.
- [x] Per-entry **share links** (public token) + anonymous shared entry/media
      ([ADR-0004](adr/0004-log-visibility.md); Phase 3) — an owner setting an entry to `public`
      mints an unguessable, revocable `share_token` (narrowing clears it; an optional
      `share_expires_at` can time-box it). `Logs.fetch_entry_by_share_token/1` is the **sole**
      anonymous read path (still-public + unexpired + non-deleted + history not hidden, else
      existence-hidden); `SharedEntryController` serves `GET /entries/shared/:token`, and the
      entry's purified media is re-authorized through the same token at
      `GET /entries/shared/:token/media/:id`. The owner copies the URL and sets/clears the expiry
      on the entry page. The grant-gated timeline still serves no anonymous callers
- [x] Verified **veterinarian accounts** (credential verification) + generated
      **health-summary report** export ([ADR-0012](adr/0012-vet-access-model.md); Phase 4) —
      `Accounts.VetProfile` (applicant page + admin review queue on `/admin`) gates the `vet`
      role on grant *and* re-grant; `Reports` freezes a point-in-time snapshot (private entries
      excluded) served to an authenticated grant or through an **expiring** anonymous share
      token (`GET /reports/shared/:token`, existence-hidden). Report bodies now **offset-page**
      for long snapshots (roadmap §8). Follow-ups: per-entry public share links (shipped), report media serving
      ([v1.1.0](#milestone-v110))

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
- [x] **Timezone-aware display & input** ([ADR-0018](adr/0018-timezone-display-policy.md)) —
      times are stored UTC but resolved to an **active zone per viewer** (user preference →
      admin **system default** → `Etc/UTC`) via `Goodmao2.Timezone`, process-scoped like the
      locale. Displayed times shift to the active zone; entered wall-clock times (log
      `occurred_at`, report share expiry) are parsed *from* it back to UTC; the calendar buckets
      by **local** day. A user sets their zone on `/users/settings` (browser-prefilled), an admin
      the system default on `/admin/settings`. Backed by the pure-Elixir `tz` database (no runtime
      HTTP). Follow-up in [v1.1.0](#milestone-v110): per-pet timezones
      (resolution is per-viewer today).

### 8. Platform & data model

- [x] **Oban** for background jobs (supersedes the deferred bespoke-job-queue plan, ADR-0006;
      Phase 1/2). Oban + `Oban.Plugins.Cron` are supervised after the repo. **Crons:** the daily
      **token janitor** (`Goodmao2.Accounts.TokenJanitor`), the daily **media orphan janitor**
      (`Goodmao2.Media.OrphanJanitor`), and the **medication reminder** worker
      (`Goodmao2.Medications.ReminderWorker`, `*/15`, ADR-0019). **On-demand:** **notification
      fan-out** (`LogFanoutWorker` / `AnnouncementFanoutWorker`, ADR-0011), **Web Push dispatch**
      (`PushDispatchWorker`, ADR-0011 Stage 2), and **media purification**
      (`Goodmao2.Media.PurifyWorker` — ffmpeg off the request path, ADR-0005).
- [x] **Data-model polish bundle** — four refinements within the existing model (no new ADR):
      **weight-unit-aware input + display** (weight is entered and shown in the pet's `weight_unit`
      — g/kg/lb — while storage stays canonical grams; conversion is centralized in
      `Goodmao2Web.Helpers`); a **richer `Species` enum** (`rabbit` / `bird` / `hamster` /
      `reptile` / `fish`, before the `other` catch-all); a **5-minute clock-skew tolerance** on the
      `occurred_at` / `ended_at` future-guards; and **`:offset` paging** on `Logs.list_entries` /
      `shareable_entries` with render-side **Prev/Next paging of long report bodies** (frozen
      snapshot, `?page=N`, on both the authenticated and anonymous report pages)
- [x] **Profile images (avatars)** for users and pets ([ADR-0020](adr/0020-profile-images.md)) —
      one polymorphic `avatars` row per owner, purified off the request path by reusing the ADR-0005
      `Purifier`/`Storage`/`Limits` primitives (images only), stored in an owner-keyed keyspace, and
      served IDOR-hidden by `AvatarController` (user avatar app-visible; pet avatar `:read`-gated).
      Rendered round-masked by the shared `<.avatar>` component; uploaded on `/users/settings` and
      the pet header (`:manage`).

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
- [x] **Two-factor authentication** ([ADR-0013](adr/0013-second-factor-authentication.md)) —
      TOTP authenticator codes (`nimble_totp` + `eqrcode` QR) with single-use HMAC-hashed recovery
      codes, and WebAuthn/FIDO2 hardware security keys (`wax_` + `cbor`) as a second factor. A
      pending-2FA login stage gates **every** primary-auth path (magic-link and password), issuing
      no session token until the factor passes; **required for the admin**, opt-in for everyone
      else; TOTP secrets AES-256-GCM-encrypted at rest; security keys hard-deleted; brute-force
      lockout on the 2FA stage plus a per-address throttle on failed password logins
      (`Accounts.LoginRateLimiter`) and same-window TOTP replay rejection (`totp_last_used_at` →
      `since:`); sudo-gated self-service at `/users/settings/two-factor`.
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
- [x] **Co-hosting deployment note** (`doc/deployment.md`) — the manual runbook for running
      GoodMao2 in production alongside a sibling Phoenix app (Baudrate) on one host: a distinct
      `PORT` (5000), Postgres role/db (`goodmao`/`goodmao2_prod`), systemd unit, `/opt/goodmao2`
      tree, and nginx `server_name` per app, with one nginx terminating TLS and routing by
      hostname (the `443` in `runtime.exs` is only the canonical-URL host, not a listener). Covers
      the release build (`mix release` + `rel/overlays/bin/{server,migrate}` + `Goodmao2.Release`,
      generated via `mix phx.gen.release`), the env file, migrate-before-activate, and the
      **Amazon SES** mailer (`Swoosh.Adapters.AmazonSES`, `AWS_SES_*` + `MAILER_FROM_EMAIL` env,
      verified-sender/sandbox caveats). Mirrors Baudrate's `ansible/` deploy conventions.
- [x] **Ansible-driven deployment** (`ansible/`) — provisioning + releases automated, mirroring
      **Baudrate's `ansible/`**: `setup-server.yml` (common/postgresql/elixir/rust/nginx roles —
      note **ffmpeg** in `common` for runtime media purification, and a `goodmao`/`goodmao2_prod`
      Postgres pair) + `deploy-goodmao2.yml` (SOPS secrets incl. the SES credential, server-side
      `mix release` from a git tag, timestamped `releases/` + atomic `current` symlink, env-file-
      sourced `bin/migrate` before swap, `/health` poll, keep-N cleanup). Distinct `PORT` 5000,
      systemd unit, and nginx `server_name` let it co-host with Baudrate; media is app-served, never
      nginx-static. (The old `my_ansible_playbooks` repo is unrelated — the reference was Baudrate's
      in-repo `ansible/`.)

### 10. Accessibility & UX polish

Delivered 2026-07-18 as one tranche — small CSS/HEEx edits in `assets/css/app.css`,
`components/layouts.ex`, `components/layouts/root.html.heex`, `components/core_components.ex`,
and a `PointerGlow` hook in `assets/js/app.js`. The **installable PWA** (2026-07-23, v0.3.0)
was added to this section later; the mobile fixes that followed it are in the changelog.

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

- [x] **Installable PWA** — a web app manifest + maskable icons, a root-scope service worker,
      and `viewport-fit=cover` + `env(safe-area-inset-*)` under
      `@media (display-mode: standalone)`. **This reverses the "out of scope" call below**: the
      objection was that offline operation is antithetical to a LiveView monolith, and that
      still holds — GoodMao caches **no** application page. What shipped is narrower and
      unrelated to offline use: a home-screen icon and a standalone window, which suit logging
      pet care on a phone at the moment it happens far better than finding a browser tab. The
      service worker precaches exactly one static page, shown when a navigation fails with no
      connection, because a fetch handler that answers navigations is an installability
      criterion — not because the app works offline. It does not.

**Explicitly out of scope** (antithetical to a LiveView monolith): **offline operation** — no
application page is ever cached, and there is no background sync or offline write queue;
no-JS progressive-enhancement form fallbacks. (The *installable* half of "PWA" shipped above.)
Phoenix hero-icons already satisfy
[ADR-0010's](adr/README.md) self-hosted/SSR-safe/tree-shaken requirements, so no separate
icon vendoring is needed. GoodMao ships a light/dark/system theme toggle.

### 11. Notes / follow-ups

- User references that are audit-only (`recorded_by_user_id`, `granted_by_user_id`,
  `created_by_user_id`) are stored without FK navigations, a deliberate
  cascade-path decision.
- The `life` log type carries **photos and videos** (ADR-0005 Phase 1, shipped); the note text
  is still required, so a media-only entry is not possible.
  The `visibility` `public` scope + per-entry share token is now **fully shipped** (ADR-0004):
  minted for owner-set public entries, served anonymously (entry + media) via
  `/entries/shared/:token`, revocable by narrowing or an optional expiry.

### v1.0.0 — released

**Shipped since this chapter was first drafted:** per-entry public share links + anonymous
shared-entry/media endpoints (ADR-0004); the **async media pipeline** — off-request-path ffmpeg
purification (`Media.PurifyWorker`) + the orphan-object janitor (ADR-0005), which closed the last
`[~]` in §8; and the **deployment tranche** (§9) — the co-hosting note (`doc/deployment.md`),
Amazon SES mailer, release scaffolding, and the **Ansible playbook** (`ansible/`) that ships
v1.0.0 to a real host alongside Baudrate.

**v1.0.0 shipped on 2026-07-23** and GoodMao is live at
[goodmao.tw](https://goodmao.tw) — its own domain, TLS, Amazon SES mail, Web Push, and
installable to a phone's home screen. The patch releases that followed the same day
(`1.0.1`–`1.0.3`) were corrections found by using the deployed app, not new scope: duplicated
security headers where the weaker copy silently won, a reconnect banner that fired every time a
phone woke from sleep, and visibility scopes that named themselves without saying what they did.

## Milestone: v1.1.0

Everything below was **consciously deferred past v1.0.0** — nothing here blocked shipping, and
nothing here is new scope invented after the fact. Each item already has an ADR or a §-section
above that scoped it out; this chapter only gathers them in one place so the tail is a list
rather than a set of asides.

The theme is **coordination**: v1.0.0 made a shared timeline possible, and what's left is
mostly about several people (and several pets) coordinating around it without the app becoming
noisy. None of it is urgent, and the order below is by the value it unlocks, not by size.

**Status key:** `[x]` shipped · `[~]` partially shipped · `[ ]` deferred.

### 1. Coordination & notification polish

The failure mode this addresses: a household with three caretakers and two pets gets a bell and
a push for every event, so the signal that matters — a missed dose — arrives in the same stream
as everything else and is learned to be ignored.

- [ ] **Medication snooze / escalation** ([ADR-0019](adr/0019-medication-schedules-and-reminders.md))
      — a reminder that can be deferred rather than only given/skipped, and one that escalates to
      other caretakers when a dose goes unhandled. Today `ReminderWorker` ages an overdue slot to
      `missed` and stops there; nobody is told twice, and nobody else is told at all.
- [ ] **Notification batching / digest** ([ADR-0011](adr/0011-notifications-and-messaging.md))
      — collapse a burst into one notification. Every bell row funnels through
      `Notifications.create/3`, so the choke point to batch at already exists.
- [ ] **Dose-history retention GC** ([ADR-0019](adr/0019-medication-schedules-and-reminders.md))
      — `medication_doses` grows one row per slot per schedule forever. A long-lived daily
      schedule is ~365 rows a year per pet; the timeline entries are the record worth keeping,
      not the slots.

### 2. Per-pet timezones

- [ ] **Resolve the display zone per pet, not only per viewer**
      ([ADR-0018](adr/0018-timezone-display-policy.md)). Times resolve through the *viewer's*
      preference today, which is right for one household in one place and wrong the moment a
      pet is boarded, rehomed across zones, or watched by a caretaker who travels: the same
      dose reads as a different hour to two people coordinating on it. Medication schedules
      already store their own IANA zone, so the pattern exists — this extends it to display and
      makes the two agree.

### 3. Media & sharing follow-ups

- [ ] **Attach media to an existing entry** ([ADR-0005](adr/0005-media-storage.md)) — media can
      only be added while creating a `life` log, so a photo taken a minute later needs a second
      entry.
- [ ] **Media in shared reports** ([ADR-0012](adr/0012-vet-access-model.md)) — a health summary
      freezes text only. A vet reading a shared report sees that a wound was logged, not the
      photo of it, which is often the point.
- [ ] **Media-only life logs** — the note text is required, so a photo cannot stand alone.

### 4. Localization completeness

- [ ] **Six strings are untranslated in `zh_TW` and `ja_JP`** — the weight-chart labels
      ("Average weight", "Daily average weight", and its sampled variant), "Conversation
      messages", and the two re-authentication flash messages. The locale-parity test asserts
      *structural* parity (same msgids, no fuzzy entries) and passes, which is exactly why this
      went unnoticed: parity is not completeness. Small and self-contained.

### 5. Operations

- [ ] **Back up the GPG key offline** — the key decrypting
      `ansible/inventory/group_vars/all.sops.yml` is the single point of failure for every
      deployment secret, including the `SECRET_KEY_BASE` that 2FA secrets and the VAPID key are
      encrypted with. Provider snapshots do not protect it (see
      [`deployment.md`](deployment.md#backups)).
- [ ] **Do one restore drill** — bring a snapshot up on a throwaway instance and confirm the app
      boots, a user passes a TOTP challenge, and a life-log photo loads. An unverified backup is
      a belief, not a backup.
- [ ] **Submit to the HSTS preload list** (optional) — the header has qualified since 1.0.1.
      Effectively permanent, and it commits every `*.goodmao.tw` subdomain to HTTPS forever, so
      it is a deliberate choice rather than an oversight.

### Not planned

- **Offline operation** — no application page is cached, and there is no background sync or
  offline write queue. See §10 of the v1.0.0 chapter: this is antithetical to a LiveView
  monolith, and the installable app deliberately does not imply it.
- **No-JS progressive-enhancement form fallbacks.**
- Everything in [Deferred / future entities](architecture.md#deferred--future-entities) that no
  item above claims.
