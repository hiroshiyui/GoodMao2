# 11. In-site notifications and a private mailbox

- **Status:** Accepted _(Stage 1 + Web Push Stage 2 shipped)_
- **Date:** 2026-07-18 _(accepted 2026-07-20; Web Push shipped 2026-07-21)_
- **Deciders:** GoodMao maintainers

> _Both stages are shipped. Stage 1: the bell feed, the private 1:1 mailbox, live PubSub
> badges, the shared-pet gate, Oban fan-out (`log_added` + admin announcements), and
> soft-delete throughout. **Web Push (Stage 2) is now shipped** — the SSRF-safe outbound
> client, RFC 8291/8188/8292 crypto (no external library), an Oban dispatch worker hooked at
> `Notifications.create/3`, browser subscription endpoints, a service worker, and admin-managed
> VAPID keys._

## Context

Co-caretakers, owners, and vets coordinate a pet's care, but the app gives them **no way
to reach each other** and **no way to learn that something happened** (access granted, a
new log recorded, a platform announcement). Two related surfaces are wanted: an **in-site
notification feed** and a **private mailbox** for user-to-user messages, each message
capped at **2,000 characters**.

Because GoodMao is a public, internet-facing service handling sensitive data, messaging
must not become a spam/harassment vector, and error copy must stay honest without leaking
(see [ADR-0007](0007-error-reporting.md)). Web Push delivery is wanted too, but it depends
on an SSRF-safe outbound client — so it is deferred to a second stage.

## Decision

**Two independent surfaces, each with its own unread badge, built on new domain entities;
many-recipient fan-out runs through Oban. Web Push is a separate, later stage.**

- **Two surfaces, not one.** A **bell** (a `notifications` feed) covers events —
  `access_granted`, `access_revoked`, `log_added`, `announcement`. A **mailbox**
  (`conversations` / `conversation_participants` / `messages`) covers private 1:1
  messaging, with its **own** unread count. A **new message is surfaced by the mailbox
  badge, not a duplicate bell entry** — two badges for one event would double-count. Both
  counts are resolved into the LiveView's assigns and kept live over **Phoenix PubSub**
  (the same backbone that already streams the timeline), so the nav badges update without
  polling.

- **Shared-pet gate (the abuse boundary).** You may **start a conversation only with
  someone you already share a pet with** (an effective `pet_accesses` grant on a common
  pet). No cold DMs to arbitrary handles. Resolving the recipient and the gate return a
  **uniform "cannot message" error** whether the recipient doesn't exist or merely shares
  no pet — never revealing which (per ADR-0007). One conversation exists per unordered
  pair (a canonical pair key). Reading/sending within a thread requires **being a
  participant** (else `not_found`, existence hidden).

- **2,000-character messages.** The message body is capped at 2,000 chars, enforced in the
  changeset and mirrored in the column length and the client counter.

- **Copy is rendered, not stored.** Notifications store a stable `type` + a denormalized
  `jsonb` payload (pet/actor names, role, announcement title/body) snapshotted at event
  time; the **display sentence is rendered through Gettext** (a `Goodmao2Web.Helpers`
  function, like the enum-label and log-summary helpers) from that `type` + payload. In a
  monolith, copy is composed at render time from stable data, localized in every locale —
  never stored as rendered strings.

- **Fan-out via Oban.** Single-recipient events (access grant/revoke) create a
  notification inline. Many-recipient events — a new log to every other follower, an admin
  announcement to every user — enqueue an Oban job, so the write path stays fast; tests
  drive the job inline. This is the first job that actually needs Oban (see
  [`../adr/README.md`](README.md) → the superseded ADR-0006).

- **Administrator announcements** are an admin-only broadcast with a compose page.

- **Soft delete throughout.** Notifications and messages carry `deleted_at` + a read
  filter; a participant row is soft-deletable for a future archive/leave path
  ([ADR-0008](0008-soft-delete.md)).

- **Web Push is Stage 2 (now shipped).** Browser-supplied push endpoints are user-supplied
  URLs, so an **SSRF-safe outbound client** (`WebPush.SafeClient` — private-range denylist
  incl. IPv4-mapped/NAT64 IPv6, DNS pinning) validates each endpoint at storage *and* send
  time. Stage 2 adds a `push_subscriptions` entity, the RFC 8291/8188/8292 crypto
  (hand-rolled on `:crypto`, **no external library**), an Oban `PushDispatchWorker` hooked at
  the single `Notifications.create/3` choke point (so all four bell types push with no drift),
  browser subscribe/unsubscribe endpoints, and a service worker — reusing the Stage-1
  notification records. **VAPID keys are managed in the admin Web UI** (`/admin/settings`),
  not env: an admin generates the keypair, the private key is AES-256-GCM encrypted at rest
  (keyed off `SECRET_KEY_BASE` via PBKDF2) in a small `settings` store. Push copy renders from
  the same `Goodmao2Web.Helpers` as the bell, in the default locale (there is no per-request
  locale in the dispatch worker). New mailbox *messages* do not push (they write no bell row);
  a future add.

## Consequences

- **Coordination lands** — followers can message and are told when things happen, without
  leaving the app, and the badges are live via PubSub at no extra round-trip.
- **New schema:** `notifications`, `conversations`, `conversation_participants`,
  `messages`, plus the fan-out Oban worker and the admin-announcement path.
- **Fan-out is unbatched** — one notification row per recipient, and Oban's at-least-once
  retry could double-post on a mid-run failure. Acceptable for a best-effort feed;
  **batching/digest is future work**, called out here so it isn't mistaken for done.
- **No email.** Deliberately out of scope (operational cost); Web Push is the outbound
  channel, staged behind its SSRF prerequisite.

- **GoodMao status (Stage 1 shipped, 2026-07-20).** Two contexts back the surfaces:
  `Goodmao2.Notifications` (feed + `notifications` table + the `LogFanoutWorker` /
  `AnnouncementFanoutWorker` Oban workers) and `Goodmao2.Messaging` (`conversations`,
  `conversation_participants`, `messages`, the shared-pet gate `can_message?/2`, and the
  per-participant read cursor). Copy is rendered from `type` + payload via
  `Goodmao2Web.Helpers.notification_summary/1`. Live badges ride a global
  `Goodmao2Web.UnreadBadges` `on_mount` hook (`attach_hook(:handle_info, …)`) so every
  authenticated LiveView updates without per-view code. Grant/revoke notify **inline** from
  `Pets`; new logs enqueue fan-out from `Logs.create_entry/3` (respecting per-entry
  `visibility`).

- **GoodMao status (Web Push Stage 2 shipped, 2026-07-21).** `Goodmao2.Notifications` gained
  Web Push: `WebPush` (RFC 8291 `encrypt/3` + delivery), `WebPush.Vapid` (ES256 JWT +
  DER→raw), `WebPush.SafeClient` (SSRF guard + DNS pinning), `WebPush.VapidVault`
  (AES-256-GCM), the `PushSubscription` schema, and the `PushDispatchWorker` — enqueued from
  `create/3` only when `WebPush.vapid_configured?/0`. A new `Goodmao2.Settings` key/value store
  (ETS-cached) holds the VAPID keypair, generated by an admin on `Goodmao2Web.AdminLive.Settings`
  (`/admin/settings`). Browsers subscribe via `Goodmao2Web.PushSubscriptionController`
  (`/api/push-subscriptions`, CSRF-protected, rate-limited); `assets/js/service_worker.js`
  (root-scope bundle) shows the notification and `assets/js/push_manager_hook.js` drives the
  opt-in on `/users/settings`.

## Alternatives considered

- **Open DMs by handle** — maximum flexibility, but a spam/harassment surface on a public
  service; the shared-pet gate fits the coordination use case and can be relaxed later.
- **One unified feed (messages as notifications)** — simpler nav, but conflates a
  read/reply inbox with an event log and double-counts message arrivals.
- **Flat messages instead of threads** — simpler, but incoherent for back-and-forth; a
  per-pair conversation is the natural model.
- **Inline fan-out on the request** — simplest, but a broadcast or a widely-shared pet
  would stall the writer; Oban is exactly the right foundation.
- **Ship Web Push now** — larger and gated on the SSRF-safe client; staging keeps the
  in-site core shippable and reviewable on its own.
