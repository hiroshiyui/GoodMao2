# 20. Profile images (avatars) for users and pets

- **Status:** Accepted _(shipped)_
- **Date:** 2026-07-22
- **Deciders:** GoodMao maintainers

> _Shipped: an optional, purified profile image for every user and every pet, rendered under a
> round mask; stored in one polymorphic `avatars` table; purified off the request path by reusing
> the LifeLog media pipeline; and served through an authorized, IDOR-hidden endpoint._

## Context

Users and pets were identified by text alone (a `@handle`/display name, a pet's name). A profile
image makes the shared timeline warmer and pets easier to tell apart at a glance. But an avatar is
still an **arbitrary user-supplied image**, so it carries the same risks the LifeLog media pipeline
already addresses ([ADR-0005](0005-media-storage.md)): EXIF/GPS leakage, alpha-channel deception,
polyglots/oversized files, and unauthorized reads. A URL field (`pets.photo_url` existed but was
never wired up) would have re-introduced SSRF and hotlinking and offered none of that hardening.

Two shape questions were distinct from ADR-0005:

1. **One current image per owner**, not a growing collection — replacement semantics, not history.
2. **Different visibility.** A pet's timeline is grant-gated, but its *avatar* is closer to its
   name — visible to anyone who can see the pet. A user's avatar is app-wide identity.

## Decision

**Add an optional avatar for each user and pet, reusing ADR-0005's purify/storage primitives but
in a dedicated polymorphic `avatars` table, an owner-keyed object store, an async purify worker,
and an authorization endpoint whose rules match the owner — not a log entry.**

- **One polymorphic table.** `avatars(owner_type ∈ {user,pet}, owner_id, status, content_type,
  byte_size, uploaded_by_user_id)` with a **unique index on `(owner_type, owner_id)`** — exactly
  one avatar per owner, the upsert target. No FK navigation (the id spans two tables; audit-only,
  per the repo convention). `pets.photo_url` is left dormant, not repurposed.

- **Images only, purified off the request path.** `Media.Avatars.set_avatar/4` stages the raw
  upload (`Media.Storage.stage/1`), upserts the row to `processing`, and enqueues an
  **`AvatarPurifyWorker`** in the same transaction — mirroring `Media.create_life_log/4`. The
  worker runs the shared `Media.Purifier` (magic-byte typing, EXIF/GPS stripped, alpha flattened
  onto opaque white, re-encoded, `Media.Limits` byte/pixel caps), **rejects video** (avatars are
  images), stores the clean bytes, flips the row to `ready`, and broadcasts. A classified failure
  drops a first-ever row (or reverts to the prior ready image) and sends the uploader an
  **`avatar_failed`** bell.

- **Owner-keyed object store, disjoint from media.** Bytes live under `storage_dir/avatars/<owner
  -key>` (`"pet-7"`), a keyspace separate from the numeric-shard media tree so an `avatar` and a
  `media_asset` sharing an integer id can never collide. The path is derived from the row, never
  stored — traversal-proof — and `updated_at` cache-busts the served URL across replacements.

- **Authorization matches the owner.** `AvatarController` serves `/avatars/user/:id` and
  `/avatars/pet/:id`, re-applying view authorization per request: a **user** avatar is visible to
  any authenticated user; a **pet** avatar requires `:read` on that pet and is otherwise
  **existence-hidden** (404, like an inaccessible media object). Responses carry the same hardening
  as `MediaController` (`nosniff`, a `default-src 'none'` sandbox CSP, `inline`). **Setting** an
  avatar is self-only for a user and needs **`:manage`** for a pet (matching `Pets.update_pet`).

- **Round mask is pure presentation.** A single `<.avatar>` component renders the served image
  under `rounded-full object-cover`, or a neutral initials disc when there is no ready avatar.
  Callers pass already-loaded avatar `meta` (`%{status, version}`; `metas_for/2` for lists) so
  the nav, pet cards, pet header, `/users/settings`, and the mailbox render with no N+1. The nav
  avatar stays live via the global `UnreadBadges` on_mount hook.

## Consequences

- **One hardening path.** Avatars inherit every ADR-0005 guarantee for free; there is no second,
  weaker image path and no URL field to SSRF.
- **Replacement, not history.** The unique-per-owner row is upserted in place; the old object is
  served until the new one overwrites it, and `updated_at` busts caches. No revision trail is kept
  — an avatar is current-state, unlike a log entry.
- **Visibility is deliberately looser than the timeline.** A pet avatar is `:read`-gated (not
  tied to entry visibility), and a user avatar is app-wide. This is intentional: an avatar is
  identity, not health data. Any future anonymous surface (e.g. a public shared entry showing the
  pet) must opt in explicitly rather than inherit this.
- **Async means a brief placeholder.** A first upload shows the initials disc until the worker
  finishes and broadcasts; a replacement briefly shows the fallback before flipping back. Accepted
  as cosmetic, in exchange for keeping ffmpeg off the request path.

## Alternatives considered

- **Columns on `users`/`pets` + no table** — rejected: spreads avatar logic across two schemas and
  still needs a separate object keyspace and a status/lifecycle field; the polymorphic table keeps
  it one concept.
- **Reuse `media_assets` with a nullable `log_entry_id`** — rejected: its NOT-NULL `log_entry_id`,
  visibility authz, and collection semantics are all wrong for a single owner-scoped current image.
- **Synchronous purification** — rejected: re-introduces the ffmpeg-on-request-path latency/DoS
  surface ADR-0005 removed, for a marginal UX gain.
- **A `photo_url` string** — rejected outright: SSRF, hotlinking, and none of the purification.
