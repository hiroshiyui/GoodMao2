# 8. Deletion is always soft — never a permanent removal

- **Status:** Accepted _(shipped for log entries)_
- **Date:** 2026-07-14
- **Deciders:** GoodMao maintainers

## Context

GoodMao's data is a **pet's health history** — everyday logs that become a **clinical
timeline** the moment a pet gets sick, plus (later) the photos and videos of a life.
That data is sensitive, sometimes sentimental, and occasionally the subject of a
shared-care disagreement (owner, co-caretakers, a vet). A destructive action on it
should be **recoverable**, and an accidental or hasty deletion should never be the end
of a record someone may need later — clinically or emotionally.

Two of the app's existing "removal" actions already reflect this instinct:

- **Ending a pet's care** is a status transition that preserves the whole record, not a
  delete ([ADR-0003](0003-pet-lifecycle.md)).
- **Revoking an access grant** flips `pet_accesses.status` to `revoked`; the grant row is
  kept.

Deleting a **log entry** must follow the same rule rather than physically removing the
row (which would also, once media exists, orphan or unlink the stored bytes). That is
irreversible, and inconsistent with the rest of the system.

## Decision

**Every delete in GoodMao is a soft delete: it hides the record, but preserves the row
(and any bytes) so it can be restored. Permanent removal is never the behaviour of a
user-facing delete.**

- **Soft-delete marker.** A deletable entity carries a nullable `deleted_at`
  (`utc_datetime`). Null = live; set = deleted. It doubles as the audit timestamp.
- **Hidden by every read.** Reads filter `deleted_at IS NULL` (a query scope applied on
  the read path in the `Logs` context), so the app behaves exactly as a hard delete looks
  from the outside — the entry vanishes from the timeline. Reaching a deleted row is
  explicit and rare (an admin restore, a janitor, a test) and uses a query that omits the
  filter deliberately.
- **Dependent data follows the parent.** Once media exists, a log entry's media assets are
  hidden with the entry, and the **stored bytes are preserved**, not unlinked.
- **The delete stamps, never removes.** Deleting an entry sets `deleted_at` and saves;
  authorization is unchanged (owner, or the entry's recorder). A second delete is a clean
  no-op (`not_found`) — the read filter already hides it.
- **This is the rule for all future deletes.** Any new deletable domain entity gets a
  `deleted_at` + read filter, not a physical delete. The status-based transitions for pets
  (ADR-0003) and access grants are the same principle expressed with a domain-specific
  status enum, and remain as they are.

**Out of scope:** internal, non-domain housekeeping — e.g. a future Oban job that purges
already-terminal infrastructure rows — is retention GC of processed records, not a
user-facing deletion, and may still hard-delete.

## Consequences

- **Recoverable by construction.** No user action destroys health data; a future restore
  path or admin tool only needs to clear `deleted_at`.
- **Consistent mental model.** "Delete hides, it doesn't destroy" holds across pets,
  grants, and logs alike.
- **Storage grows.** Soft-deleted rows (and, later, their media) accumulate. A future
  **retention janitor** (an Oban job) may _hard_-purge rows soft-deleted beyond a
  retention window; that is a separate, operator-governed policy, not a user action.
- **The read filter is load-bearing.** Any query that bypasses the `Logs` read path must
  consciously re-apply `deleted_at IS NULL`, or it will leak deleted rows. Prefer a shared
  query scope so the filter is not re-derived per call site.

## Alternatives considered

- **Hard delete** — simplest and self-cleaning, but irreversible and unfit for sensitive,
  sentimental health data; also inconsistent with ADR-0003.
- **A separate `is_deleted` boolean** — needs a second column for the "when", and a bare
  flag invites "deleted but no audit trail." A single nullable `deleted_at` is both flag
  and timestamp.
- **An archive/tombstone table** (move deleted rows aside) — preserves data but
  complicates every restore/report query; a column + read filter is far simpler and keeps
  the row addressable in place.
