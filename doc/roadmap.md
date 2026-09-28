# GoodMao — Roadmap

_Last updated: 2026-09-28_

## Overview

GoodMao was built **depth-first from the core**. The heart of the product (effortless
structured logging, producing a shareable, authorized timeline) shipped first and in full. This
file tracks what's done, what's open, and what was ruled out. Implementation detail lives in
[`architecture.md`](architecture.md), the ADRs and [`CHANGELOG.md`](../CHANGELOG.md), so the
entries here stay short.

**Where things stand:** [v1.0.0](#milestone-v100) shipped on 2026-07-23 and is live at
[goodmao.tw](https://goodmao.tw). The latest release is **v1.5.0** (2026-09-25), and main also
carries unreleased hardening from the Baudrate comparison. The
[releases since v1.0.0](#releases-since-v100) were mostly hardening: two project-wide reviews, a
security audit, browser-driven tests, a runtime upgrade, and that comparison. The open work is
in two lists:

- [**Deferred from v1.0.0**](#open-deferred-from-v100): coordination polish, payload range
  validation, per-pet timezones, the media and sharing tail, and operations.
- [**Lessons from Baudrate**](#backlog-lessons-from-baudrate-2026-09-28): the larger features
  left over after the sibling project's recent fixes were checked against this codebase.

**Status key** (open lists only): `[x]` shipped · `[~]` partially shipped · `[ ]` open.

### Vision

The classic vet-visit problem is that owners reconstruct history from memory, badly. GoodMao
makes **effortless structured daily logging** that produces a **shareable health timeline**. The
social layer isn't decoration: it is how the clinical value reaches the vet.

**One-line pitch:** effortless structured daily logging that produces a shareable health
timeline vets can actually use.

GoodMao is for pets people love, and sometimes grieve. The product should be **thoughtful,
gracious, and affable**: warm, never rushing a heavy moment, and letting people record the truth
of their situation. That is why end-of-care preserves the record and can be backdated
([ADR-0003](adr/0003-pet-lifecycle.md)), and why error copy stays honest without leaking
anything ([ADR-0007](adr/0007-error-reporting.md)).

## Milestone: v1.0.0

The first public release, **shipped 2026-07-23**. It covers the depth-first core, the
enforcement-gap hardening, and the clinical-timeline, localization, engineering/ops and
accessibility work. A **hardening audit** (2026-07-18) across the backend, the UI/a11y and the
tooling fed §4, §9 and §10. This chapter records what was built, so its entries carry no
checkboxes. Section numbers are stable, because code and ADRs cite them (e.g. "roadmap §8").

### 1. Core principle: structured logging

Free text ("seemed off today 😟") is clinically useless. The heart of the product is
**structured, one-tap log entries** a vet can act on. If logging isn't effortless, nobody logs
consistently, and inconsistent logs make the vet feature worthless. Free-text notes exist
*alongside* structured fields, never instead of them. The daily types, with their per-type
fields in [`architecture.md`](architecture.md), are:

- food intake (full / partial / **refused**)
- water intake
- bathroom (a `straining` signal, because **urinary blockage in cats is an emergency**)
- vomiting and diarrhea episodes
- weight (in the pet's unit)
- energy and mood (1–5)
- medication given

### 2. Vet access model

1. **Time-boxed live access.** An owner grants a vet an expiring `pet_accesses` grant. The
   `vet` role can go only to a user with a **verified** `VetProfile`, checked on grant *and*
   re-grant ([ADR-0012](adr/0012-vet-access-model.md)).
2. **Health summary report.** A frozen snapshot over a date range that excludes private
   entries. Any effective grant can read it, and it can be shared through an expiring anonymous
   link.

### 3. MVP core

- **Auth and admin:** scope-based auth (`phx.gen.auth`), the first user becomes administrator,
  an editable `@handle`, and a read-only `/admin` overview.
- **Pets:** CRUD, coat colour and weight unit. End-of-care is owner-only, reversible and
  backdatable. `history_hidden` is enforced on reads and writes
  ([ADR-0003](adr/0003-pet-lifecycle.md)).
- **Access:** resource-based per-pet authorization, with roles, capability levels,
  time-boxed grants, the ≥1-owner invariant and IDOR-hidden 404s. A Sharing page grants and
  revokes access by `@handle` or email.
- **Logging:** structured entries in one table (`type` + `jsonb`) with per-type validation and
  one-tap QuickLog. Entries have a backdatable `occurred_at`, a note, and per-entry
  `visibility` ([ADR-0004](adr/0004-log-visibility.md)). Vets author `vet_note` entries, and
  deletes are soft.
- **Timeline:** live and type-filterable over PubSub, shown as a list or a month calendar.

### 4. Near-term hardening — enforcement gaps

The 2026-07-18 audit found seven rules **modeled but not enforced**. All were closed at the
context boundary, each with a test in both directions:

- `history_hidden` on every `Logs` read and write
- `private` visibility on reads and live pushes
- the ≥1-owner invariant on update and expiry, row-locked against concurrent revokes
- recorder-or-owner checks on edit and delete
- the optional `site_owner_email` first-registration gate
- handle-rule parity

### 5. Clinical logging & timeline

- **Weight trend chart:** inline, CSP-safe SVG with daily-average points per local day, and a
  change shown by arrow and sign, not colour alone.
- **Medication schedules and reminders**
  ([ADR-0019](adr/0019-medication-schedules-and-reminders.md)): durable dose slots, an atomic
  "given" claim that writes the timeline entry, and a `*/15` reminder cron with bell and push.
- **LifeLog photos and videos** ([ADR-0005](adr/0005-media-storage.md)), purified with ffmpeg
  off the request path. They are served authorized and IDOR-hidden, and a janitor reclaims
  orphans.
- **Edit revisions** ([ADR-0009](adr/0009-log-edit-revisions.md)): every real edit is
  snapshotted, and an entry allows at most nine edits.
- **Clinical flag chips** (urgent / watch), shown by icon, text and shape. One
  `Helpers.clinical_flags/1` drives both the chips and the calendar tint.
- **One-tap QuickLog buttons** for common values, with the full form behind "More options".

### 6. Sharing, notifications & vet workflow

- **Bell feed and 1:1 mailbox** with live unread badges
  ([ADR-0011](adr/0011-notifications-and-messaging.md)). Starting a conversation requires a
  shared pet, and a refusal never reveals whether the other user exists.
- **Web Push:** hand-rolled RFC 8291/8188/8292 over an SSRF-safe, DNS-pinned client, with
  VAPID keys generated from the admin UI.
- **Per-entry public share links** ([ADR-0004](adr/0004-log-visibility.md)), which are the
  only anonymous read path. They can be revoked and time-boxed, and cover the entry's media.
- **Verified vet accounts and health-summary reports** ([ADR-0012](adr/0012-vet-access-model.md)),
  with expiring share links and paged report bodies.

### 7. Localization & typography

- **Per-request locale** (cookie → `Accept-Language` → default), a header switcher, and a
  localized wordmark ([ADR-0002](adr/0002-culture-first-localization.md)).
- **Complete `en` / `zh_TW` / `ja_JP` catalogs**, the `phx.gen.auth` pages included.
- **Self-hosted Roboto Slab** for Latin text, with CJK falling through to native faces.
- **A 20 px base reading size** and a text-size control.
- **Timezone-aware display and input** ([ADR-0018](adr/0018-timezone-display-policy.md)):
  times are stored in UTC and resolved from the user's preference, then the system default, then
  UTC. The calendar buckets entries by local day.

### 8. Platform & data model

- **Oban** for background jobs (superseding ADR-0006's bespoke queue): three crons (token
  janitor, media orphan janitor, medication reminders) and on-demand jobs for fan-out, push
  and purification.
- **Data-model polish:**
  - weight entered and shown in the pet's unit and stored in grams
  - a broader `Species` enum
  - a 5-minute clock-skew tolerance on future-date guards
  - `:offset` paging for the timeline and report bodies
- **Profile images** for users and pets ([ADR-0020](adr/0020-profile-images.md)), reusing the
  media purifier and storage.

### 9. Engineering & ops maturity

- **CI and Dependabot.**
- **The `mix precommit` gate:** compile warnings, format, `deps.audit`, `hex.audit` and
  Sobelow.
- **Operational basics:** `/health`, seeds that refuse to run outside `:dev`, and
  `CHANGELOG.md`.
- **Content-Security-Policy** with a per-request nonce.
- **Two-factor authentication** ([ADR-0013](adr/0013-second-factor-authentication.md)): TOTP,
  recovery codes and WebAuthn security keys. It is required for the admin, and no session is
  issued until the factor passes.
- **`mix goodmao.doctor`**, a preflight check.
- **Locale-parity test** and the `a11y-engineering` skill.
- **Deployment:** a co-hosting runbook ([`deployment.md`](deployment.md)) and Ansible
  provisioning and releases modeled on Baudrate's `ansible/`, with Amazon SES mail.

### 10. Accessibility & UX polish

- A skip link, a `:focus-visible` brand ring, and `aria-hidden` on decorative icons.
- A global `prefers-reduced-motion` guard.
- Elevation and motion tokens.
- `theme-color`, an SVG favicon, and the "· GoodMao" title suffix.
- A sticky app shell with a footer.
- Pointer glow (off under reduced motion).
- A light/dark/system theme toggle.
- **An installable PWA:** manifest, maskable icons, a root-scope service worker, and
  safe-area insets. The app **caches no application page**. The service worker precaches one
  offline page only because a navigation handler is an installability criterion. See
  [Not planned](#not-planned).

## Releases since v1.0.0

The [changelog](../CHANGELOG.md) has the detail.

| Release | Date | What it was |
|---|---|---|
| 1.0.1–1.0.5 | 07-23 – 07-30 | Corrections found by using the live app: duplicate security headers where the weaker copy won, a reconnect banner on every phone wake, and unclear visibility names. Media and avatars revalidate by `ETag`. Localization completeness (Open §4). |
| 1.1.0–1.2.0 | 07-31 | A life log's media can be managed after creation (Open §3). Multi-frame phone JPEGs purify, and a noisy ffprobe no longer loses an upload silently. Upload progress bars. |
| 1.2.1 | 08-03 | Project-wide review; see below. |
| 1.2.2 | 09-13 | Six advisories patched (Bandit, Mint, Postgrex, LiveView), all found by `hex.audit` only. |
| 1.3.0 | 09-18 | Security audit: OTP TLS CVEs, a readable Erlang distribution cookie ([ADR-0021](adr/0021-loopback-erlang-distribution-and-per-server-cookie.md)), pet pages that kept streaming after access ended, and an unbounded TOTP brute force. Messaging now follows the shared pet. |
| 1.4.0 | 09-20 | QuickLog had saved every entry `private`, and form errors weren't announced. The first browser-driven tests (`mix test.feature`). |
| 1.5.0 | 09-25 | Erlang/OTP 29 and Elixir 1.20, one runtime pin across dev, CI and production, the type checker as a gate, and browser tests in CI. |
| Unreleased | 09-28 | The [Baudrate backlog](#backlog-lessons-from-baudrate-2026-09-28)'s security, test/CI and accessibility items, including a rate-limiter crash that Dialyzer found. |

> **What the reviews taught, as classes of bug.** These come from the 2026-08-03 review (1.2.1),
> the 2026-09-18 audit (1.3.0) and the 2026-09-28 Baudrate comparison.
>
> - **A capability check left off one verb.** A caretaker demoted to `viewer` could still delete
>   what they had logged: being the recorder is not a capability.
> - **A gate every attacker already satisfies.** `/users/two-factor/complete` admitted anyone
>   past the password step, so a stolen password alone minted a session.
> - **An invariant documented but never implemented.** WebAuthn sign-count regression was
>   claimed and not enforced, so cloned keys authenticated.
> - **A limit kept where the attacker controls it.** The TOTP attempt cap lived in the session
>   cookie, and replaying the pre-failure cookie reset it.
> - **Authorization checked once, then trusted.** Live pages kept rendering pushes after a grant
>   ended, so every pushed entry is now re-authorized.
> - **One shared queue, one unbounded wait.** Hung ffmpeg processes could stall medication
>   reminders. Media now has its own queue and a hard deadline.
> - **A gate that passed a vulnerable build.** `mix_audit`'s database lacked a HIGH advisory.
>   The gate now runs `hex.audit` as well.
> - **AA contrast lost to alpha.** Token *pairs* pass, but `/50` and `/60` opacity text doesn't,
>   so `/70` is the floor.
> - **Nothing ran the client.** A `<select>` default made QuickLog save everything `private`
>   behind a green suite. Browser tests now run in CI.
> - **A crash a supervisor hides.** The login and registration limiters passed their table to
>   `:ets.foldl/3` in the wrong position. Every sweep crashed, and each restart wiped the
>   counters, so the hourly limits were really ten-minute ones. Only Dialyzer noticed.
> - **A copy that drifts from its source.** The hand-deploy nginx example appended
>   `X-Forwarded-For` long after the template stopped. Tests now hold both to the same rules.

## Open: deferred from v1.0.0

These were **consciously deferred past v1.0.0**, each scoped out by an ADR or a section above.
The list was first drafted as "Milestone v1.1.0". The releases since then went to hardening
instead, so it is tracked by section rather than by version number. The theme is
**coordination**: several people and several pets working from one timeline without the app
becoming noisy. Items are ordered by the value they unlock.

### 1. Coordination & notification polish

A household with three caretakers and two pets gets a bell and a push for every event, so a
missed dose arrives in the same stream as everything else and learns to be ignored.

- [ ] **Medication snooze and escalation** ([ADR-0019](adr/0019-medication-schedules-and-reminders.md)).
      Let a reminder be deferred, and escalate an unhandled dose to other caretakers. Today an
      overdue slot turns `missed` and nobody is told twice.
- [ ] **Notification batching and digests** ([ADR-0011](adr/0011-notifications-and-messaging.md)).
      Collapse a burst into one notification at the existing `Notifications.create/3` choke
      point.
- [ ] **Dose-history retention GC.** `medication_doses` gains a row per slot forever (about 365
      a year per daily schedule). The timeline entries are the record worth keeping.

### 1b. Log payload range validation

- [ ] **Validate payload values for meaning, not only type**
      ([ADR-0015](adr/0015-structured-one-table-logging.md)). An `energy.level` of 99, a
      `symptom.severity` of 0 or a negative `weight_grams` all persist today, and the chart
      plots them. The 1–5 scales are a convention the schema doesn't enforce.

### 2. Per-pet timezones

- [ ] **Resolve the display zone per pet, not only per viewer**
      ([ADR-0018](adr/0018-timezone-display-policy.md)). This matters for boarding, rehoming
      and travelling caretakers, when the same dose reads as a different hour to two people.
      Medication schedules already store their own zone.

### 3. Media & sharing follow-ups

- [x] **Attach media to an existing entry** ([ADR-0005](adr/0005-media-storage.md)). Shipped in
      1.1.0.
- [ ] **Media in shared reports** ([ADR-0012](adr/0012-vet-access-model.md)). A vet reading a
      report sees that a wound was logged, not the photo of it.
- [ ] **Media-only life logs.** The note is required, so a photo can't stand alone.

### 4. Localization completeness

- [x] **Shipped 2026-07-23.** `zh_TW` and `ja_JP` have no untranslated entries. The parity test
      now asserts completeness and placeholder parity, not just matching msgids. Six empty
      `msgstr`s had passed it: one was an `aria-label` and three were in a screen-reader table,
      so they reached only the users the localization was for.

### 5. Operations

- [ ] **Back up the GPG key offline.** It decrypts every deployment secret, including the
      `SECRET_KEY_BASE` that 2FA secrets and the VAPID key are encrypted with. Provider
      snapshots don't cover it ([`deployment.md`](deployment.md#backups)).
- [ ] **Do one restore drill:** boot a snapshot on a throwaway instance, pass a TOTP
      challenge, and load a photo.
- [ ] **Submit to the HSTS preload list** (optional, and effectively permanent for every
      `*.goodmao.tw` subdomain).

## Backlog: lessons from Baudrate (2026-09-28)

Baudrate, the sibling Phoenix app this project takes its conventions from, went from v1.33.1
to v2.0.3 (`11eeb8e`..`de8ae293`) in about 1,450 commits. About 70 of them fixed a *class* of
problem GoodMao2 could share. Each was checked against this codebase, and only the gaps
confirmed to exist were listed. The [changelog](../CHANGELOG.md)'s Unreleased section has the
detail.

### Shipped 2026-09-28 (unreleased)

- **Security:**
  - Message pushes name the sender and never show the text, and are tagged per subject.
  - The nginx example in [`deployment.md`](deployment.md) sets `X-Forwarded-For` and redacts
    tokens.
  - Ansible runs `nginx -t` before a reload and restores the old config on failure.
  - The timeline page and every paging offset are bounded.
  - Avatar uploads are rate-limited.
  - Share pages send `noindex`.
  - A grant is revoked, and its user notified, exactly once.
- **Tests and CI:**
  - The `.pot` templates must be up to date, with file-only references.
  - The locale parity test is stricter, and every enum label must be translated.
  - A CI static job runs Dialyzer (which found the rate-limiter crash), `cargo clippy` and
    `cargo test`, and `ansible-lint`, and CI publishes a coverage report.
  - `rustup-init` is SHA-256-pinned.
  - A test ties nginx's static paths to `static_paths/0`.
  - Async tests no longer queue on the single-admin index.
- **UX and accessibility:**
  - Uploaders describe their photos, and the description becomes the alt text.
  - Copy and share never fail silently.
  - Mixed CJK and Latin text gets automatic spacing (`text-autospace`).
  - Repeated icon buttons each name their own item, and the avatar cropper is described
    properly.
  - Lists that re-render on PubSub are keyed.

### Open: larger features

These need product decisions before they're built.

- [ ] **A session list with "sign out other sessions"** (`d06b4f85`). Today a lost phone is cut
      off only by changing the password, and a magic-link user may not have one.
- [ ] **Delete your own account** (`27e10d84`). Anonymize the user and keep the row
      ([ADR-0008](adr/0008-soft-delete.md)), because a hard delete cascades into other people's
      conversations. Refuse the admin and any pet's sole owner.
- [ ] **Notification filters, grouping and per-type preferences** (`4edca778`, `a47e4b9d`).
      This builds on Open §1's batching item. Use separate site and push keys, so turning one
      off never resets the other.
- [ ] **An admin view of failed background jobs** (`74869753`), with retry and abandon allowed
      only from states where they make sense.
- [ ] **An `l10n-engineering` skill, run before every release** (`9b9ff29e`, `77a7bce1`,
      `460cef75`). Compact the skill files at the same time. `code-review` still calls
      translation a deferred follow-up.

## Not planned

- **Offline operation.** No application page is cached, and there is no background sync or
  offline write queue. This is antithetical to a LiveView monolith. The installable app
  (v1.0.0 §10) deliberately doesn't imply it.
- **No-JS progressive-enhancement form fallbacks.**
