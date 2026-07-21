# 14. Resource-based per-pet authorization

- **Status:** Accepted _(shipped; foundational — recorded retroactively)_
- **Date:** 2026-07-21
- **Deciders:** GoodMao maintainers

> _Foundational decision, in place since the MVP core and depended on by nearly every
> other ADR (0003, 0004, 0008, 0011, 0012). Written down now so the security boundary it
> defines is recorded, not just implied by the code._

## Context

A pet's timeline is **shared health data**: an owner, one or more co-caretakers, casual
viewers (family), and — time-boxed — a vet all touch the same records with **different
rights**. The classic ways to model this both fail GoodMao:

- **A global role on the user** ("this user is a caretaker") can't express that Ada is an
  *owner of Rex* but only a *viewer of Momo*. Access is a property of the **(user, pet)
  pair**, not of the user.
- **An admin backdoor** — letting the site administrator read any pet — would betray the
  product's promise. The administrator is a global operational role ([ADR-0016](0016-scope-based-auth-and-first-user-admin.md));
  it must grant **no** access to anyone's pet data.

Two further forces shape the model:

1. **Access is temporal.** A vet gets access *for a visit*. Rights must be able to expire
   and be revoked without deleting history.
2. **Existence itself is sensitive.** Probing `/pets/123` must not reveal whether pet 123
   exists. The app is IDOR-defensive: an inaccessible pet is indistinguishable from a
   missing one.

## Decision

**Authorization is computed per request from an *effective grant* — never from a global
role — over four roles and three capability levels, and an inaccessible resource is
reported as not-found.**

- **Effective grant.** Every (user, pet) right is a `pet_accesses` row with a `role`, an
  optional `expires_at`, and a `status`. A grant is **effective** only when
  `status == "active"` **and** it has not expired (`Pets.effective_access/2`). All reads
  and writes authorize from the *effective* grant recomputed on each call — there is no
  cached "is this user a caretaker" bit to go stale.

- **Roles × capability levels.** Four roles map to three capability levels
  (`Pets.can?/3`, `role_allows?/2`):

  | role | `:read` | `:write` (author logs) | `:manage` (edit pet, lifecycle, grants) |
  | ---- | :-----: | :--------------------: | :-------------------------------------: |
  | `owner`        | ✓ | ✓ | ✓ |
  | `co_caretaker` | ✓ | ✓ |   |
  | `vet`          | ✓ | ✓ |   |
  | `viewer`       | ✓ |   |   |

  Capabilities are the coarse gate; finer per-type rules layer on top in the context
  (e.g. `vet_note` is vet-only — [ADR-0009](0009-log-edit-revisions.md) — and changing a
  log's `visibility` is owner-only — [ADR-0004](0004-log-visibility.md)).

- **IDOR-hidden reads.** `Pets.fetch_pet(user, id, require: level)` returns
  `{:error, :not_found}` for a pet the caller cannot access at that level — **never**
  `:forbidden`. Missing and inaccessible are the same outward answer; existence never
  leaks. List queries join the effective-grant filter, so a caller only ever sees pets
  they hold a grant on.

- **The ≥1-owner invariant.** A pet must always have at least one effective owner. Creating
  a pet inserts the creator's `owner` grant in the **same transaction**. Revoking, demoting,
  or time-boxing the last owner is refused (`{:error, :last_owner}`). Because two concurrent
  revokes could each see the other owner as still-effective and both commit (write skew),
  owner-invariant mutations run inside a transaction that takes `FOR UPDATE` on the pet's
  owner rows (`with_owner_lock/2`), serializing them.

- **The `vet` role is gated on verification.** Granting or re-granting `vet` requires the
  grantee to hold a **verified** `VetProfile` (`{:error, :vet_not_verified}` otherwise),
  checked on the shared grant/re-grant path — [ADR-0012](0012-vet-access-model.md).

- **No admin backdoor.** The global `is_admin` role is orthogonal to pet access; admin code
  paths never call the pet reads with elevated rights. Admin oversight surfaces show
  aggregates and identities, never pet data.

## Consequences

- **`Pets` is the security boundary.** Authorization lives in the context, not the
  LiveView — a crafted request or a new caller can't skip it. LiveViews authorize in
  `mount` via `fetch_pet/3` and `push_navigate` on failure, but that is convenience, not
  the guarantee.
- **Every read pays for a grant lookup.** Recomputing the effective grant per request costs
  a query, but keeps rights correct across expiry/revocation with no invalidation logic —
  the simplest thing that cannot be stale.
- **"Forbidden" is never a distinguishable response.** Error copy and status handling must
  keep inaccessible and missing identical, or the IDOR posture erodes ([ADR-0007](0007-error-reporting.md)).
- **The owner lock is load-bearing.** Any new owner-affecting mutation must run through
  `with_owner_lock/2` (or an equivalent `FOR UPDATE` on owner rows), or write skew can
  strand a pet with zero owners.
- Downstream features inherit this: notification/report fan-out uses
  `list_effective_accesses/1` as the true current follower set; the log visibility tiers
  ([ADR-0004](0004-log-visibility.md)) and soft-delete ([ADR-0008](0008-soft-delete.md))
  all sit *inside* this boundary.

## Alternatives considered

- **Global role on the user** — rejected: cannot express per-pet, per-role rights, and
  would make the admin a de facto super-reader of all pets.
- **Per-request ACL check in each LiveView** — rejected: authorization must live at the
  context boundary so non-web callers (workers, controllers, tests) get the same guarantee
  and a forgotten check can't open a hole.
- **A cached/materialized "capabilities" projection per user** — rejected: adds an
  invalidation problem on every grant/expiry/revoke for a query that is already cheap;
  correctness-by-recomputation is simpler and cannot go stale.
- **Return `403 Forbidden` for inaccessible pets** — rejected: leaks existence and enables
  enumeration; not-found is the only non-leaking answer.
- **Enforce the ≥1-owner rule with a DB constraint** — rejected: "at least one *effective*
  owner" depends on `status` and a time comparison, which a static `CHECK` can't express;
  the transactional `FOR UPDATE` guard enforces it precisely where owner grants change.
