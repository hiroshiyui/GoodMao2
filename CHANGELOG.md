# Changelog

All notable changes to GoodMao are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to adhere
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version of record is
the `version:` in `mix.exs`; a release tags it as `vX.Y.Z` (see the `release-engineering`
skill).

## [Unreleased]

## [0.2.2] - 2026-07-23

Bug fixes found while putting the first production deployment through its paces. Two of them
made the app effectively unusable for entering Chinese or Japanese text — the locales half this
project is built for.

### Fixed

- **Typing into a QuickLog field no longer closes the form.** A `<details>` element's open state
  is DOM-only and absent from the server render, so every `phx-change` echo patched the "More
  options" panel back to closed on the very first keystroke — taking focus, and with it any
  in-flight IME composition, so bopomofo could never be composed into a character. A new
  `DisclosureState` hook remembers the state on `toggle` and re-applies it after each update.
  The panel closing affected every user; it was simply most destructive for IME input.
- **The mobile menu and locale switcher no longer snap shut on unrelated updates.** The live
  unread badges render *inside* `#nav-menu`, so a notification or message arriving over PubSub
  patched the element and closed an open menu. Both dropdowns now reuse `DisclosureState` with an
  opt-in `data-close-on-navigate`, which preserves state across unrelated patches while still
  dismissing the menu when one of its own links is tapped. Only `redirect`/`patch` navigation
  closes it — `phx:page-loading-start` also fires for ordinary events flagged `phx-page-loading`.
- **`phx-change` is now held while an IME is composing** (`blockPhxChangeWhileComposing`, which
  LiveView defaults to off) and re-fired on `compositionend`, so a server round-trip can no longer
  patch a focused input mid-character. Applies to every `phx-change` input in the app.
- **Setting a first password no longer asks for a password that does not exist.** Registration is
  magic-link only, so a new account has no `hashed_password`; the page nonetheless demanded users
  "confirm your current password" and marked the field required, so the browser blocked submission
  until they invented a value the server then discarded. It now titles itself **Set password**,
  explains that sign-in is by magic link, and omits the field — matching
  `User.validate_current_password/2`, which already skipped the check in this case. Accounts that
  do have a password see the unchanged gated form, and the controller's authoritative
  re-verification is untouched.

## [0.2.1] - 2026-07-23

A deployment-readiness release. No application code changed — the built artifact is functionally
identical to 0.2.0 — but the first production go-live surfaced gaps in the deployment
configuration and runbook that are fixed here.

### Fixed

- **Amazon SES region now points at the verified identity.** `aws_ses_region` defaulted to
  `us-east-1`, but the `goodmao.tw` identity is verified in `ap-northeast-3` (Osaka) and its Easy
  DKIM CNAMEs are region-pinned. SES identities are region-scoped, so the mismatch failed in the
  worst possible way: `config/runtime.exs` reads the variable at boot, the release starts cleanly,
  and then *every* send fails as an unverified identity. The value now carries a comment
  explaining why it must track the region the domain was verified in.

### Added

- **SOPS-encrypted production secrets** (`ansible/inventory/group_vars/all.sops.yml`) holding the
  database password, `secret_key_base`, and the SES IAM credential, with `.sops.yaml` pointed at
  the operator's GPG key. Only values are encrypted, so keys stay diffable; the file is safe to
  commit because decryption requires the operator's private key.
- **A first go-live checklist** in `doc/deployment.md` — an ordered, one-time path through the
  work Ansible cannot do for you: SES production access and DNS, admin registration and its
  mandatory 2FA enrolment, the runtime-only settings (Web Push VAPID keys, default timezone, media
  limits), and the database/media backups that are **not** yet automated.
- **The SES DNS contract**, documented: the five records the identity needs (three Easy DKIM
  CNAMEs plus the custom MAIL FROM `MX`/SPF pair, alongside DMARC), why SPF belongs on the
  `mail.` subdomain rather than the apex, and `dig` commands to verify each from outside. Includes
  the **Gandi trailing-dot trap** — an unterminated value silently gets the zone origin appended,
  which SES reports as a missing domain while the domain is demonstrably fine — and how to tell a
  local zone error from AWS-side DKIM key-publication lag. Also records that the zone has no apex
  `MX`, so nothing receives mail at the domain.
- **The SES-vs-SendGrid decision record**, capturing why SES was chosen for transactional auth
  mail (no monthly floor, deliverability parity at low volume, already integrated), the ~10-line
  Swoosh path to switch, and the conditions that would justify revisiting it.

## [0.2.0] - 2026-07-23

The full product build-out on top of the 0.1.0 MVP core: media and log editing, medication
coordination, the vet access model and health reports, in-site notifications and a private
mailbox with Web Push, two-factor authentication, a timezone display/input policy, profile
avatars, per-entry sharing, a trilingual UI, and the production deployment story. Everything is
backward compatible with 0.1.0; every user-visible string is localized in en / 台灣漢語 / 日本語.

### Added

#### Clinical logging & timeline

- **Weight trend chart** — the pet page shows the pet's weight over time as an inline SVG line
  chart (server-rendered, CSP-safe), appearing once there are two or more measurements. Readings
  are aggregated into one **daily-average** point per *local* day and the x-axis is partitioned
  strictly by calendar day (faint x/y scale lines; per-day dots dropped past ~45 days; the sr-only
  data table evenly sampled for long histories). It headlines the latest value and its signed
  change since the first day (a trend arrow **and** a +/− value, never colour alone); clicking a
  point reveals its date and weight (`WeightChart` JS hook, with a native `<title>` hover fallback
  in the static report). Fed by `Logs.weight_series/3` (visibility- and hidden-history-aware) and
  live over PubSub.
- **Log editing with an audited revision trail (ADR-0009)** — log entries can be edited on a
  dedicated entry page (`/pets/:pet_id/logs/:id`), and every real edit records an immutable
  snapshot of the prior state (type, data, note, time, visibility — never the share token) in a
  `log_entry_revisions` table. A no-op edit records nothing; the type is immutable on edit; and an
  entry may be edited at most nine times ("a cat's nine lives"), tracked by a denormalized
  `edit_count`. The revision history follows the entry's own read authorization, so it renders for
  readers, not just editors; the timeline marks edited entries.
- **One-tap QuickLog** — the common log values are each their own submit button (Food ate
  fully / partially / refused, Water normal / low / high, Bathroom urine / stool, Vomited),
  logging in a single tap; the full manual form moves into a "More options" disclosure.
- **Clinical flag chips on the timeline** — high-signal cues surface as urgent/watch chips
  (urinary blood/straining, not eating, repeated vomiting, severe symptom), each carrying an icon
  **and** text **and** a level-specific shape, never colour alone (WCAG 1.4.1). A single
  `Helpers.clinical_flags/1` is the source of truth, from which the calendar's day-cell tint is
  derived, so timeline and calendar can never disagree.
- **Calendar view for the pet timeline** — read the timeline as a month grid alongside the
  chronological list, toggled by a segmented control; each day cell shows its entry count plus a
  clinical cue, and picking a day expands that day's entries. Days bucket by **local** day.
- **Timeline pagination** — a per-page size control (persisted as a user preference), `:offset`
  paging on `Logs.list_entries`, and scroll-into-view on page changes.
- **Weight-unit-aware entry & display** — weight is entered and shown in the pet's `weight_unit`.
- **Daily-life logs (`life` type)** — any caretaker can author a daily-life note from QuickLog.
- **Per-entry share links (ADR-0004)** — an owner can mint an unguessable, optionally-expiring
  share token for a `public` entry; a single anonymous, existence-hidden shared-entry page serves
  it (`GET /entries/shared/:token`), and shared media rides the same token.

#### Media

- **Purified LifeLog photos & videos (ADR-0005)** — a daily-life log can carry images and video,
  uploaded through the app and **actively purified off the request path** (Oban): magic-byte
  typing, EXIF/GPS stripped by re-encode, images re-encoded with alpha flattened onto opaque
  white, a codec allow-list + duration cap for video, all via ffmpeg. Byte-size caps and min/max
  pixel dimensions are **admin-configurable** (`Media.Limits`). Objects are stored id-keyed and
  opaque (physical path never stored), served only via an authorized, IDOR-hidden `GET /media/:id`
  (`Range`, hardened headers), with a daily **orphan janitor** reclaiming stray/staged objects.
  Uploads are rate-limited. New CI/deploy dependency: ffmpeg on `PATH`.
- **Profile-image avatars for users & pets (ADR-0020)** — optional round-masked avatars reusing
  the same purify/storage/limits primitives (images only, separate keyspace). A user avatar is
  self-only and visible to any authenticated user; a pet avatar needs `:manage` and is
  `:read`-gated & IDOR-hidden. Uploads offer a **client-side square crop** applied
  authoritatively server-side in the same re-encode.

#### Medications

- **Medication schedules, doses & reminders (ADR-0019)** — recurring **schedules** (each with its
  own IANA timezone) materialize durable **dose slots** (wall-clock → UTC, idempotent). Marking a
  dose given is an atomic `pending → given` claim (TOCTOU-safe) that writes a normal `medication`
  timeline entry — one history, no parallel log. An Oban cron (`ReminderWorker`, `*/15`) fills the
  horizon, ages overdue slots to `missed`, and fans out a de-duped `medication_due` bell + Web
  Push to effective `:write` caretakers. Managed on `PetLive.Medications`.

#### Vet access & health reports

- **Vet access model — verified profiles & health reports (ADR-0012)** — the `vet` role is
  grantable only to a user with a **verified** `VetProfile` (submitted on `/users/vet-profile`,
  reviewed in the admin queue). `Reports.generate_report/3` freezes a shareable `jsonb` snapshot
  over a date range that **excludes every `private` entry**, with an optional expiring share link
  (only the token's SHA-256 hash stored). Vets author authoritative `vet_note` entries via a
  role-gated QuickLog path.

#### Notifications & messaging

- **In-site bell feed + private 1:1 mailbox (ADR-0011)** — per-recipient notification rows keyed
  by `type` (copy rendered at read time), covering grants/revokes, added logs (respecting
  visibility), medication reminders, media failures, and admin announcements (fanned out via
  Oban). A private mailbox allows 1:1 conversations, gated to users who share a pet, with
  read cursors and soft-deleted messages. Live nav unread badges via a global `on_mount` hook.
- **Web Push delivery + admin-managed VAPID (ADR-0011 Stage 2)** — every bell row (and each new
  mailbox message) can deliver a Web Push, hand-rolling RFC 8291/8188/8292 on `:crypto`. The
  outbound client is **SSRF-safe and DNS-pinned** (private-range denylist incl. IPv4-mapped /
  NAT64); browsers subscribe via a CSRF- and rate-limited endpoint. VAPID keys are managed on
  `/admin/settings`.

#### Accounts & authentication

- **Two-factor authentication — TOTP + WebAuthn (ADR-0013)** — opt-in for everyone, **required for
  the administrator**. TOTP (via `nimble_totp`/`eqrcode`) with single-use HMAC-hashed recovery
  codes and single-window replay rejection; FIDO2 security keys (via `wax_`/`cbor`) with
  sign-count regression enforcement. Primary auth (password *and* magic-link) routes through a
  pending-2FA challenge stage that issues no session token until a factor is re-verified
  server-side; secrets are encrypted / recovery codes hashed at rest.
- **Registration hardening (ADR-0016)** — per-address sliding-window rate limits on registration
  and magic-link emails, existence-hidden registration (no account-enumeration oracle), and a
  **single-administrator** database constraint.
- **Isolated, gated change-password** — password change is separated from the settings form and
  re-verifies the current password (and sudo mode).

#### Platform & operations

- **Timezone display/input policy (ADR-0018)** — times are stored UTC and resolved to an **active
  zone per viewer** (user preference → admin system default → `Etc/UTC`), process-scoped like the
  Gettext locale. Display shifts UTC → local; every `datetime-local` input (log `occurred_at`,
  end-of-care `ended_at`, grant `expires_at`) converts wall-clock → UTC before the changeset and
  prefills back to local, via the shared `Helpers.put_local_datetime/4` / `to_datetime_local/2`.
  Users pick a zone on `/users/settings` (browser-prefilled); an admin sets the system default.
  Backed by the pure-Elixir `tz` database.
- **Rust NIF native boundary (ADR-0017)** — a `Goodmao2.Native` Rustler crate
  (`native/goodmao2_native`) built by `mix compile`, toolchain pinned by `rust-toolchain.toml`.
  Proven scaffolding (currently a placeholder `add/2`) for future CPU-bound work.
- **Background jobs (Oban) + token janitor** — Postgres-backed Oban with `Oban.Plugins.Cron`; a
  daily `TokenJanitor` prunes expired auth tokens. Foundation for the media/reminder/fan-out/push
  workloads above.
- **Administrator surface (`/admin`, `/admin/settings`)** — an admin-only, IDOR-hidden site
  overview and vet-credential review queue, plus a settings page managing the Web Push VAPID
  keypair, the system default timezone, and the media upload limits. Administration is a global
  role that grants **no** pet-data access.
- **Production email via Amazon SES**, **`mix release` scaffolding**, a **co-hosting deployment
  runbook**, and an **Ansible playbook** for the deployment story.
- **CI / Dependabot / security tooling** — a GitHub Actions gate (compile with
  warnings-as-errors, format, unused-deps, `mix_audit`, `sobelow`, full test suite) against a
  Postgres service; weekly grouped Dependabot updates; the audit + scan also run in
  `mix precommit`.
- **`GET /health`** liveness/readiness probe, a per-request **nonce-based CSP**,
  **`mix goodmao.doctor`** environment preflight, a **locale-parity test**, and **dev HTTPS on
  `:4001`**.

#### i18n, UX & docs

- **Trilingual UI (en / 台灣漢語 / 日本語)** — per-request locale resolution (cookie →
  `Accept-Language` → default), a language switcher that persists the choice, `<html lang>`
  reflection, and a Gettext-backed brand wordmark (`GoodMao` / `顧毛` / `グッドマオ`, ADR-0002).
  The `zh_TW` / `ja_JP` catalogs are culturally localized, and every feature above ships localized.
- **Larger default text + a font-size control** (20px base, −/+ control, persisted, applied
  pre-paint), **Roboto Slab as the general alphanumeric font with a CJK-aware fallback chain**,
  and a **localized page title on every route** (WCAG 2.4.2).
- **Accessibility & UX polish** — skip-to-content link, `:focus-visible` brand ring,
  `aria-hidden` decorative icons, a global `prefers-reduced-motion` guard, elevation/motion design
  tokens, a `theme-color` meta + inline SVG favicon, a sticky app-shell + footer, and the
  **`a11y-engineering`** Claude skill.
- **Project documentation** — glossary, ADRs (0004–0020), a common-practices reference, and
  expanded roadmap sections; the **"Terracotta + Teal"** brand as WCAG-verified daisyUI
  light/dark themes.
- **License — AGPL-3.0-or-later** — the full `LICENSE` text, a README License section (with the
  vendored Roboto Slab staying under Apache-2.0), and a `licenses:` entry in `mix.exs`.

### Changed

- **Responsive primary navigation** — the header collapses into a hamburger disclosure on small
  screens (CSP-safe `<details>`, no added JS) and stays an inline bar at `lg`+.
- **Language switcher moved to the footer** — the locale chooser opens upward from the page foot,
  decluttering the top bar.
- **Past pets moved off the active list** — ended companions have their own quiet memorial surface
  at `/pets/past`, reached by a subtle link from Account settings rather than the everyday list
  (ADR-0003), and are shown in a muted, graceful tone rather than warning-amber.
- **Species enum expanded** to the full set of companion animals.
- **Clock-skew tolerance** — `occurred_at` / `ended_at` future-guards allow a 5-minute skew.
- Hard-fenced `priv/repo/seeds.exs` to `:dev` so demo accounts can never be planted in
  staging/production.

### Fixed

- **Timezone consistency for datetime-local inputs** — end-of-care `ended_at` and grant
  `expires_at` now interpret the entered wall-clock in the viewer's zone and store UTC (and
  prefill back to local), matching the log forms, instead of storing the browser value as if UTC.
- Re-stream the notifications feed and messages inbox on live updates; keep the avatar uploader
  popover open across re-renders; wrap the pet-actions nav so it doesn't overflow on mobile;
  harden avatar-crop accessibility and robustness; and a sweep of security-audit minor findings.

### Security

- **Enforced modeled-but-unenforced authorization/visibility rules** (parity audit):
  `history_hidden` on every log read/write, per-entry `private` visibility on reads and the live
  timeline, recorder-or-owner scoping on log edit/delete, the ≥1-owner invariant on the
  grant-update path with a `FOR UPDATE` row lock, an optional site-owner gate on the bootstrap
  administrator, and stricter `@handle` rules.
- **Registration hardening (ADR-0016)** — per-address rate limits, existence-hidden registration,
  and the single-administrator database constraint.
- **Secret handling** — the Web Push VAPID private key and 2FA TOTP secrets are AES-256-GCM
  encrypted at rest (keyed off `SECRET_KEY_BASE`), recovery codes are HMAC-hashed, and the Web
  Push outbound client is SSRF-safe and DNS-pinned.

## [0.1.0] - 2026-07-18

Initial GoodMao baseline — the Phoenix/LiveView MVP core: scope-based
authentication with a public `@handle`, pets with an end-of-care lifecycle, resource-based
per-pet authorization, structured one-table log entries, and a live, filterable timeline
over Phoenix PubSub. Trilingual Gettext scaffolding (`en` / `zh_TW` / `ja_JP`) and the
`mix precommit` gate.
