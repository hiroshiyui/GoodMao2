# 4. Log entry visibility scopes

- **Status:** Accepted _(schema shipped; anonymous read + owner UI deferred)_
- **Date:** 2026-07-10
- **Deciders:** GoodMao maintainers

## Context

At its simplest, read access to a pet's timeline is all-or-nothing: any user with an
effective `pet_accesses` grant (co-caretaker, viewer, or vet) can read **every**
log entry. Health data is sensitive, and that single tier is too coarse:

- An owner may want to keep some entries to themselves (a candid note, a sensitive
  observation) without revoking a co-caretaker's broader access.
- Conversely, an owner may want to make a specific entry **shareable with someone
  who has no account and no grant** — e.g. sending a single vomiting log to a vet
  clinic, or a weight chart to a breeder — without exposing the rest of the pet.

The hard constraint is our security-first, IDOR-defensive model: the pet-scoped reads
authorize from the caller's effective grant and hide existence (`Pets.fetch_pet/3`
returns `{:error, :not_found}`, never "forbidden"). Any "public" mechanism must **not**
turn those reads into an anonymous surface, or it would unravel that model.

## Decision

**We give each log entry a `visibility` scope, controlled only by owners, and expose
"public" solely through an unlisted, revocable share token — never by opening the
grant-scoped reads.**

- **`visibility` ∈ `private | limited | public`** on `log_entries`, defaulting to
  **`limited`** (which preserves the base behavior). Reads are filtered by scope:
  - **private** — readable only by effective **owners** and the entry's **recorder**
    (`recorded_by_user_id`). Hidden from other followers, and absent from their list
    (existence hidden, consistent with our IDOR convention).
  - **limited** — any follower with an effective grant (the default).
  - **public** — every follower, **plus** anyone holding the entry's share token.
- **Owners are the only role that can change a log's visibility** (enforced in the
  `Logs` context at the boundary, not only in the LiveView). Setting **public** mints a
  URL-safe **share token**; setting any narrower scope **clears it** (revocation). The
  token is surfaced only to owners.
- **Anonymous public reads go through one dedicated path** (a public route/LiveView,
  not the grant-gated timeline). It returns the entry only when the token matches,
  the entry is still `public`, **and** the pet's history is not hidden
  (`history_hidden` — see [ADR-0003](0003-pet-lifecycle.md) — overrides a live link).
  The grant-gated timeline never serves anonymous callers.

## Consequences

- Owners get a private tier and a shareable tier without touching the grant model;
  the sensitive default (`limited`) is unchanged, so existing readers keep working.
- The only anonymous read path is a single token-guarded route with an
  unguessable, non-enumerable, revocable key — the IDOR posture of the grant-gated
  timeline is untouched.
- Owners can revoke a shared link at any time (narrow the scope), and hiding a pet's
  history also kills its outstanding links.
- New surface to maintain: a unique filtered index on the share token, exposed in views
  only to owners (never to plain viewers/vets).
- **GoodMao status:** the `visibility` enum and the owner-only change rule are
  **shipped**; the `public` scope + share token are **modeled in the schema**, but the
  anonymous read route and the owner-facing share-link/scope-selector UI are **deferred**
  (roadmap Phase 3). Per-recipient sharing (grant one external vet a scoped link) is out
  of scope; a future ADR may revisit.

## Alternatives considered

- **Per-entry ACLs (a visibility grant per user per log)** — maximally flexible but
  far too heavy for one-tap logging; an authorization matrix per entry is unusable
  and slow. Rejected in favor of three coarse scopes.
- **Expose public entries on the grant-gated timeline to anonymous callers** — would
  make the pet timeline serve unauthenticated reads and leak pet existence,
  breaking the IDOR model. Rejected; public reads are isolated to the token route.
- **A single boolean `is_public` flag** — covers sharing but not the private tier the
  owners asked for, and still needs the token mechanism. Rejected in favor of the
  three-value enum.
