# GoodMao — Glossary

Shared vocabulary for the project. Keep it current as concepts are added or change.
Deeper detail lives in [`architecture.md`](architecture.md) and [`roadmap.md`](roadmap.md);
the reasoning behind cross-cutting decisions lives in [`adr/`](adr/).

The **Product & domain** terms below describe what GoodMao is; the **Architecture & tech**
terms name its Phoenix/LiveView/Ecto/Gettext stack.

## Product & domain

- **GoodMao (顧毛)** — the product. From 「照顧毛小孩」, "take care of your pets"
  (English; the zh-TW 毛小孩 endearment is localized per culture — see _Culture-first
  localization_). Warm, owner-first framing; the clinical timeline is the payoff.
- **Pet** — an animal a user cares for. Species-aware (cat-first). Ownership is a
  role, not a column (see _Owner_).
- **Owner** — a `pet_accesses` role granting full control of a pet: manage grants,
  edit the pet, end its care, and log. A pet can have **multiple equal co-owners** and
  must always retain **at least one** owner (the ≥1-owner invariant).
- **Co-caretaker** — a `pet_accesses` role that can read and write logs but not manage
  grants or the pet (e.g. a family member or sitter).
- **Viewer** — a read-only follower; may see only curated highlights.
- **Veterinarian (Vet)** — a **verified** professional account. As a per-pet role,
  a vet can read the full clinical timeline and author vet notes; vet access is
  typically **time-boxed**. "Verified" is a global account attribute (a `VetProfile`),
  distinct from per-pet roles — the `vet` role is only grantable to a verified profile.
- **VetProfile** — the account-level record proving veterinarian status
  (license, licensing body, region, clinic, verification status). The `vet` per-pet role
  requires it to be **verified**; an administrator reviews submissions on `/admin`. See
  [ADR-0012](adr/0012-vet-access-model.md).
- **Administrator** — the one **global** (non-per-pet) role, for platform oversight
  (e.g. vet verification). It deliberately **does not** bypass resource-based pet
  authorization — no backdoor to a user's pet health data. In GoodMao the **first
  registered account** is bootstrapped as the sole administrator (`users.is_admin`).
- **Handle (`@handle`)** — every account's **public** identifier (e.g. `@johndoe`) — the
  thing you mention or invite a user by. Lowercase-canonical, case-insensitively unique
  (a `citext` column); distinct from the login email and the free-text `display_name`.
  Chosen at registration and editable in settings; the grant flow accepts a `@handle`
  **or** an email.
- **PetAccess** — the per-`(pet, user)` grant that carries the role, who granted it,
  optional expiry, and status. The authorization core. One row per user per pet
  (`pet_accesses`, unique on `(pet_id, user_id)`).
- **Effective access** — a `pet_accesses` grant that is `active` **and** unexpired
  (`expires_at` null or in the future). Access checks require an effective grant.
- **Time-boxed access** — a grant with an `expires_at` (typical for a vet during a
  visit); expires automatically without revocation.
- **Log entry** — a single structured, timestamped health record (food, water,
  bathroom, vomit, weight, energy, medication, symptom, vet note, life). Structured
  fields are first-class; free-text notes only accompany them.
- **LifeLog (`life` type)** — a daily-life log subtype for a pet's everyday moments. Any
  caretaker can author one from QuickLog as a **text caption** (the base `note`, which is
  required for this type). Backdatable like any log (it is often posted days later). Its
  eventual **photo/video** enrichment is _deferred_ — the media upload/serving layer
  (ADR-0005) is not yet built, but the text log itself ships today.
- **Media purification** — the (deferred) rule that **every uploaded byte is actively
  cleaned, never stored as-is**: content type is sniffed from magic bytes (SVG rejected),
  images are re-encoded to strip EXIF/GPS/polyglots, and videos are validated then
  remuxed to drop metadata. Uploads always flow **through** the app (no pre-signed browser
  upload). See [ADR-0005](adr/0005-media-storage.md).
- **Structured logging** — the principle that entries are one-tap, typed, and
  clinically queryable, never free-text blobs. The heart of the product.
- **One-table logs** — all log-entry subtypes share **one `log_entries` table** with a
  `type` discriminator and a `jsonb` `data` payload — one table for all log subtypes.
  Per-type field validation lives in `LogEntry.changeset/2`.
- **Timeline** — the chronological view of a pet's log entries; becomes the clinical
  record a vet reads. Rendered live in `PetLive.Show` and updated over PubSub.
- **Pet lifecycle status** — where a pet is in its life with the household:
  `active` (default) or an **end-of-care** state (`passed_away`, `rehomed`, `lost`,
  `other`). Recorded on the pet, with `ended_at` timestamping the exit.
- **End of care** — the owner-only transition (the `EndOfCare` LiveView) that sets an
  end-of-care lifecycle status. It **preserves the record and timeline** (not a
  deletion); ended pets leave the active list but stay viewable, and logging remains
  allowed for final notes. The end date is **backdatable** (a grieving owner rarely
  records it the same day). See [ADR-0003](adr/0003-pet-lifecycle.md).
- **Past pets** — the memorial listing of a caller's ended pets, separated from active
  pets in `PetLive.Index` — so they are findable, not lost.
- **Hidden history** — an owner opt-in (`history_hidden`) that fully hides a pet's
  timeline. Reversible and independent of lifecycle status.
- **Log visibility** — a per-log-entry read scope: `private` (owners + the recorder),
  `limited` (any effective grant — the default), or `public` (followers plus anyone
  with the entry's share token). Only owners change it. See
  [ADR-0004](adr/0004-log-visibility.md).
- **Share token** — an unlisted, unguessable, revocable token that grants anonymous
  read of a single `public` log entry; the only read path outside the per-pet grant
  model. _Deferred_ — the `public` scope + token are modeled; the anonymous read route
  and owner-facing UI are not yet built.
- **Log edit revision ("nine lives")** — each real edit to a log entry would snapshot
  the prior state to an immutable revision (readable by anyone who can read the entry)
  and increment an edit count, capped at **nine edits**. _Deferred_ — see
  [ADR-0009](adr/0009-log-edit-revisions.md).
- **Soft delete** — every user-facing delete marks the row (a nullable `deleted_at`)
  rather than removing it; every read filters `deleted_at IS NULL`, so it looks like a
  hard delete from outside while the row is preserved. Pet end-of-care and grant
  revocation express the same principle via a status enum. See
  [ADR-0008](adr/0008-soft-delete.md).
- **Medication** — an ongoing prescription/schedule; `medication` log entries record
  actual administrations (backs the "did anyone give the pill?" coordination).
  _Deferred_ — administrations are loggable today; schedules/reminders are Phase 1/3.
- **Health summary report** — a generated point-in-time export of a pet's logs for a
  vet: a **frozen snapshot** over a date range (private entries excluded), viewable/printable
  by any effective grant and shareable via an **expiring** anonymous token. See
  [ADR-0012](adr/0012-vet-access-model.md).
- **Notification** — an in-site event delivered to one user's **bell** feed
  (`access_granted`, `access_revoked`, `log_added`, `announcement`), with its own live unread
  badge. The display copy is **rendered** from a stored `type` + `jsonb` payload, never stored
  as a string. See [ADR-0011](adr/0011-notifications-and-messaging.md).
- **Mailbox / Conversation** — private 1:1 messaging between users, organized as per-pair
  conversation threads (one row per **unordered user pair**). Messages are capped at **2,000
  characters** and carry a separate unread badge from the bell. See
  [ADR-0011](adr/0011-notifications-and-messaging.md).
- **Shared-pet gate** — the messaging abuse boundary: you may **start** a conversation only
  with someone you already share a pet with (an effective grant on a common pet) — no cold DMs.
  A failed attempt returns a **uniform, non-leaking** refusal that never reveals whether the
  recipient exists (ADR-0007).
- **Read cursor** — a conversation participant's `last_read_at`: a message is unread for them
  when it arrived after this timestamp (and they didn't send it). Drives the per-thread and
  mailbox unread counts.
- **Fan-out** — creating one notification row **per recipient** for a many-recipient event
  (`log_added` to every other viewer of the entry; an `announcement` to every user), run
  through **Oban** so the write path stays fast.
- **Announcement** — an Administrator broadcast that fans an `announcement` notification
  out to every user (composed on `/admin/announcements`).
- **Web Push** — OS-level delivery of the four bell events **and new mailbox messages** to a
  user's browser even with GoodMao closed (ADR-0011 Stage 2). Opt-in per device on
  `/users/settings`, best-effort, and dispatched through **Oban** (from the `notifications`
  rows for bell events; from `Messaging.send_message/3` for messages). Rendered in the site's
  default locale (no per-request locale off the request path).
- **Push subscription** — the browser endpoint + encryption keys (`p256dh`/`auth`) a user
  registered for Web Push. The `endpoint` is browser-supplied, so it is SSRF-validated before
  storage; a `410 Gone` from the push service soft-deletes it.
- **毛小孩 (fur kid)** — affectionate Taiwanese term for a pet; the product's tone.
  Localized per culture, not transliterated (English "pets", Japanese ペット) — see
  _Culture-first localization_.
- **Culture-first localization** — the policy that UI copy is translated to each
  locale's cultural context, not carried over literally from the Chinese source: the
  brand renders as **グッドマオ** in ja-JP (the coined 顧毛 is unreadable there), the
  zh-TW locale is labelled **台灣漢語**, and pet wording uses each language's natural
  term. Recorded in [ADR-0002](adr/0002-culture-first-localization.md).

## Architecture & tech

- **Monolith / single tier** — GoodMao is one **Phoenix** application: server-rendered
  **LiveView** pages call the domain **contexts** directly. There is no separate frontend
  and no JSON API — the whole app is one deployable.
- **Context** — an Elixir/Phoenix bounded module owning a slice of the domain and its
  Ecto schemas. GoodMao has three: **`Accounts`**, **`Pets`** (the authorization core),
  and **`Logs`**. Web LiveViews are thin and call into them.
- **Scope-based auth** — `phx.gen.auth`'s pattern where the caller is
  `socket.assigns.current_scope.user`; magic-link + password login.
- **Resource-based authorization** — deciding access from the caller's *relationship to
  a specific pet* (their effective `pet_accesses` grant), not just "is logged in." Guards
  against IDOR on health data. Computed per request by `Goodmao2.Pets.can?/3` and
  `Pets.fetch_pet/3` (which returns `{:error, :not_found}` — never "forbidden").
- **Capability level** — the access tier an action requires: `:read`, `:write`, or
  `:manage`. A role maps to a set of levels; `Pets.can?(pet, user, level)` is the check.
- **PubSub** — Phoenix.PubSub, the real-time backbone. `Logs` broadcasts create/update/
  delete on a pet's topic so `PetLive.Show` streams live timeline updates.
- **Ecto** — the Elixir data-mapping/query library over PostgreSQL. `jsonb` carries the
  per-type log `data` payload and species-specific fields.
- **Audit reference** — a plain user-id column stored **without an FK navigation**
  (`recorded_by_user_id`, `granted_by_user_id`, `created_by_user_id`). Deliberate: avoids
  the multiple-cascade-path problem.
- **Gettext** — the i18n library. Message IDs extract to `priv/gettext/default.pot` and
  merge into per-locale `.po` catalogs. Locales: **English** (`en`,
  default/reference), **台灣漢語** (`zh_TW`), **Japanese** (`ja_JP`). Enum-label
  translations and log summaries live in `Goodmao2Web.Helpers`.
- **Tailwind v4 + daisyUI** — the styling stack from the `phx.new` scaffold.
- **Oban** — the durable, DB-backed background-job library GoodMao will adopt **when a
  job actually needs it** (media janitor, reminders, notification fan-out); deferred until
  required. See [ADR-0006 (superseded)](adr/README.md).
- **VAPID** — the Web Push server-identity keypair (RFC 8292; ECDSA P-256). The public key
  is handed to the browser; the private key signs a short-lived ES256 JWT per push. GoodMao
  generates it from the **admin Web UI** (`/admin/settings`) and stores it in the `settings`
  table — the private key AES-256-GCM-encrypted (`WebPush.VapidVault`, keyed off
  `SECRET_KEY_BASE`). Rotating `SECRET_KEY_BASE` requires regenerating the keys.
- **SSRF-safe client** — `WebPush.SafeClient`, the outbound HTTP client for push delivery.
  Because push endpoints are user-supplied URLs, it resolves DNS, rejects private/loopback
  addresses (IPv4 and IPv6, incl. IPv4-mapped/NAT64), and **pins** the connection to the
  resolved IP (defeating DNS-rebinding) while keeping the original SNI/Host.
- **System settings** — a small admin-managed key/value store (`Goodmao2.Settings`, ETS-cached)
  for site-wide configuration set from the Web UI. First use: the Web Push VAPID keypair.
- **`mix precommit`** — the single gate (compile with warnings-as-errors + unused-deps
  check + format + full test suite) that humans and agents run before finishing.
