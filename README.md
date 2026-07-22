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
- **i18n** — every user-visible string goes through Gettext, with the `en`, `zh_TW`, and
  `ja_JP` catalogs **fully translated** and culturally localized (a locale switcher, a
  per-culture brand wordmark, and a locale-parity test that keeps the three in structural
  sync).
- **Accessibility & ops** — skip-link, focus-visible ring, reduced-motion guard, a −/+
  text-size control and light/dark/system theme; a per-request Content-Security-Policy,
  per-address throttling of failed logins and auth emails, a `/health` endpoint, a
  `mix goodmao.doctor` preflight, and a supervised **Oban** cron that prunes expired auth tokens.

See [`doc/roadmap.md`](doc/roadmap.md) for what's deferred.

## Prerequisites

- Elixir `~> 1.15` / OTP 26+ (developed on Elixir 1.19 / OTP 28)
- PostgreSQL (a `goodmao2` role with `CREATEDB`; see `config/dev.exs` / `config/test.exs`)
- **`ffmpeg` + `ffprobe`** on `PATH` — required to upload/purify LifeLog media (photos and
  videos); the rest of the app runs without them

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
  accounts.ex            #   auth + profile/handle + first-user-admin  (phx.gen.auth)
  pets.ex                #   pets, access grants, resource authorization
  logs.ex                #   structured entries + timeline + revisions + PubSub
  media.ex               #   purified LifeLog photos/videos (ffmpeg + id-keyed storage)
lib/goodmao2_web/
  live/pet_live/         #   Index · Form · Show(QuickLog+timeline) · LogEntry · Access · EndOfCare
  live/admin_live.ex     #   read-only /admin site overview
  controllers/           #   media (GET /media/:id) · health · locale · session
  helpers.ex             #   enum-label translations + log summaries
  components/layouts.ex  #   app shell / nav
doc/architecture.md      # contexts, schema, authorization
doc/roadmap.md           # what's built and what's deferred
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
