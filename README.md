# GoodMao 顧毛

> 「照顧毛小孩」— take care of your pets.

A pet health-care web app. Owners log **structured daily activity** for their pets
and share it with followers — family, co-caretakers, and **veterinarians**. Everyday
logs become a **clinical timeline** the moment a pet gets sick.

GoodMao is a single, real-time **Phoenix/LiveView** monolith. See
[`doc/architecture.md`](doc/architecture.md) for the design.

## What's built

- **Accounts** — `phx.gen.auth` scope-based auth (magic-link + password). The first
  registered account becomes the sole **administrator** (with a read-only `/admin`
  site-overview page); every account has an editable public **`@handle`** used for invites.
- **Two-factor authentication** — **TOTP** authenticator-app codes (with single-use recovery
  codes) and **WebAuthn/FIDO2** hardware security keys as a second factor. A pending-2FA stage
  gates every sign-in path (magic-link *and* password), so no session is issued until the factor
  passes; **required for the administrator**, opt-in for everyone else. TOTP secrets are
  encrypted at rest, recovery codes are hashed, and a used TOTP code can't be replayed within
  its window; managed self-service on `/users/settings/two-factor`.
- **Pets** — create / list / view / edit, coat colour, and an owner-only **end-of-care**
  lifecycle transition (a status change, never a deletion — the record and timeline are
  preserved). An opt-in `history_hidden` flag exists-hides a pet's logs.
- **Resource-based authorization** — per-pet access grants (`owner` / `co_caretaker` /
  `viewer` / `vet`) with capability levels (`:read` / `:write` / `:manage`), time-boxed
  grants for vets, the **≥1-owner invariant**, and IDOR-hidden 404s. There is **no admin
  backdoor** to pet data.
- **Structured logging** — one-tap **QuickLog** for food, water, bathroom, vomiting,
  weight, energy, medication, symptoms, and daily-life notes; typed payloads stored in a
  single table with a `type` discriminator + `jsonb` `data`. Free-text notes ride
  *alongside* the structured fields. Vets author authoritative `vet_note` entries. Edits
  are capped and snapshot an append-only **revision history**.
- **Live timeline** — chronological *or* month-**calendar** view, filterable by type,
  updating in real time via Phoenix PubSub (a co-caretaker's entry appears instantly for
  everyone watching the pet). Highest-signal cues surface as **clinical flag chips**
  (icon + text + shape, never colour alone), and an inline CSP-safe **daily-average
  weight-trend chart** tracks weight over time (click a point for its date and value). Entries
  are **soft-deleted** (`deleted_at`), never hard-deleted.
- **LifeLog media** — a `life` log can carry photos/videos, uploaded through the app and
  **actively purified with ffmpeg** (magic-byte typing, EXIF/GPS stripped by re-encode,
  codec allow-list + duration cap), stored as id-keyed opaque objects and served only via
  an authorized, IDOR-hidden `GET /media/:id`.
- **Profile images** — optional avatars for users *and* pets, purified through the same
  ffmpeg pipeline (images only) with an in-browser square crop that the server re-applies
  authoritatively. A pet's avatar is `:read`-gated like the rest of its data.
- **Medication schedules & reminders** — recurring schedules in the schedule's own timezone,
  materialized into durable dose slots. Marking a dose given is an atomic claim (two
  caretakers can't double-record) that writes a normal `medication` entry, so there is one
  timeline and no parallel history. Overdue slots age to `missed`, and a cron worker reminds
  every caretaker who can act.
- **Health summary reports** — a frozen, point-in-time snapshot over a date range, generated
  by an owner and readable by any effective grant. Private entries are excluded from the
  snapshot itself, so an optional **expiring share link** can be handed to a vet who has no
  account. Only the token's SHA-256 hash is stored.
- **Notifications & Web Push** — an in-site bell feed (grants, new logs respecting per-entry
  visibility, medication reminders, admin announcements) whose copy is rendered at read time
  rather than stored, with unread badges that update live across every page. The same rows
  drive **Web Push** to the phone: RFC 8291/8188/8292 hand-rolled on `:crypto`, an SSRF-safe
  DNS-pinned outbound client, and an encrypted VAPID key.
- **Private messaging** — a 1:1 mailbox between users who already share a pet, with read
  cursors and soft-deleted messages. Attempting to message anyone else returns one uniform
  error whether they are unknown, yourself, or simply unshared.
- **Timezones** — times are stored UTC and resolved per viewer (user preference → system
  default → UTC), so every timestamp, `datetime-local` input, and calendar day-bucket reflects
  the reader's own clock.
- **Installable app (PWA)** — a web app manifest, maskable icons, and safe-area-aware layout
  make GoodMao installable to a phone's home screen, which is where pet care actually gets
  logged. **It is not an offline app**: no page is ever cached (they are all authenticated and
  per-viewer), only a small static page shown when a navigation finds no connection.
- **i18n** — every user-visible string goes through Gettext, with the `en`, `zh_TW`, and
  `ja_JP` catalogs **fully translated** and culturally localized (a locale switcher, a
  per-culture brand wordmark, and a locale-parity test that keeps the three in structural
  sync).
- **Accessibility & ops** — skip-link, focus-visible ring, reduced-motion guard, a −/+
  text-size control and light/dark/system theme; a per-request Content-Security-Policy,
  per-address throttling of failed logins and auth emails, a `/health` endpoint, a
  `mix goodmao.doctor` preflight, and a supervised **Oban** cron that prunes expired auth tokens.

GoodMao is deployed and in production; [`doc/deployment.md`](doc/deployment.md) is the
go-live runbook (Ansible provisioning, SOPS-encrypted secrets, SES mail, DNS, backups), and
[`doc/roadmap.md`](doc/roadmap.md) covers what's deferred.

## Prerequisites

- Elixir `~> 1.15` / OTP 26+ (developed on Elixir 1.19 / OTP 28)
- PostgreSQL (a `goodmao2` role with `CREATEDB`; see `config/dev.exs` / `config/test.exs`)
- **`ffmpeg` + `ffprobe`** on `PATH` — required to upload/purify LifeLog media (photos and
  videos) and profile images; the rest of the app runs without them
- **Rust** — `mix compile` builds the `native/goodmao2_native` crate
  ([ADR-0017](doc/adr/0017-rust-nif-native-boundary.md)). The version is pinned by
  `rust-toolchain.toml`, which `rustup` installs automatically; without a toolchain the
  project does not compile at all

## Getting started

```bash
mix setup                 # deps + create/migrate DB + seed demo data + build assets
mix phx.gen.cert          # one-time: self-signed dev TLS cert (for HTTPS on :4001)
mix phx.server            # http://localhost:4000  and  https://localhost:4001
```

The dev server listens on **both** plain HTTP (`:4000`) and HTTPS (`:4001`, a
self-signed cert in `priv/cert/`; accept the browser warning). The cert is
git-ignored and regenerable — run `mix phx.gen.cert` once after cloning.

Demo accounts (from `priv/repo/seeds.exs`):

| Email | Password | Who |
|---|---|---|
| `owner@example.com` | `password1234!` | `@amy`, owns the cat *Mochi* |
| `vet@example.com` | `password1234!` | `@dr_lin`, holds a time-boxed vet grant on *Mochi* |

> Auth uses magic-link confirmation; in development, delivered emails appear at
> [`/dev/mailbox`](http://localhost:4000/dev/mailbox). The seeded accounts are
> pre-confirmed with a password so you can log in directly.

## Development

```bash
mix precommit             # compile (warnings-as-errors) + unused-deps + format + test
mix test                  # run the suite
mix test test/goodmao2/pets_test.exs
```

## Layout

```
lib/goodmao2/            # contexts (domain)
  accounts.ex            #   auth + profile/handle + first-user-admin + 2FA  (phx.gen.auth)
  pets.ex                #   pets, access grants, resource authorization
  logs.ex                #   structured entries + timeline + revisions + PubSub
  media.ex               #   purified LifeLog photos/videos + avatars (ffmpeg, id-keyed)
  medications.ex         #   schedules, materialized dose slots, reminders
  reports.ex             #   frozen health-summary snapshots + expiring share links
  notifications.ex       #   bell feed + Web Push dispatch
  messaging.ex           #   1:1 mailbox (shared-pet gated)
  settings.ex            #   admin-managed key/value system settings (ETS-cached)
  timezone.ex            #   per-viewer timezone resolution + UTC<->local conversion
  native.ex              #   Rust NIF boundary (native/goodmao2_native)
lib/goodmao2_web/
  live/pet_live/         #   Index · Form · Show(QuickLog+timeline) · LogEntry · Access ·
                         #   EndOfCare · Medications · Reports
  live/user_live/        #   settings, 2FA, vet profile
  live/admin_live.ex     #   read-only /admin overview + vet-credential review queue
  controllers/           #   media · avatars · reports · shared entries · push · health
  helpers.ex             #   enum-label translations + log summaries + clinical flags
  components/layouts.ex  #   app shell / nav
assets/js/               # LiveView hooks + the service worker (built to the site root)
native/goodmao2_native/  # Rust NIF crate (Rustler; toolchain pinned by rust-toolchain.toml)
ansible/                 # server provisioning + release deployment (SOPS-encrypted secrets)
doc/architecture.md      # contexts, schema, authorization
doc/roadmap.md           # what's built and what's deferred
doc/deployment.md        # go-live runbook, DNS/mail, backups
doc/adr/                 # why the architectural turns were taken
```

## License

Copyright (C) 2026 Hui-Hong You &lt;hiroshi@ghostsinthelab.org&gt;

GoodMao is free software, licensed under the **GNU Affero General Public License,
version 3 or (at your option) any later version** (`AGPL-3.0-or-later`).

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the [`LICENSE`](LICENSE) file for the full text, or
<https://www.gnu.org/licenses/agpl-3.0.html>.

Because the AGPL covers use over a network, if you run a modified version of
GoodMao as a network service, you must offer its users the corresponding source.

### Bundled third-party assets

- **Roboto Slab** (`priv/static/fonts/`) — © Google, licensed under the
  [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). Its terms apply
  to the font files independently of the project's AGPL license.
