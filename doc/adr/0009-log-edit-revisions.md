# 9. Log-entry edit history, capped at nine edits

- **Status:** Proposed _(deferred — design captured ahead of implementation)_
- **Date:** 2026-07-14
- **Deciders:** GoodMao maintainers

> _Ported from GoodMao ADR-0009, adapted for the GoodMao2 Ecto stack. Editing and its
> revision trail are not yet built — this is the spec to satisfy when they are._

## Context

A log entry is part of a pet's **clinical timeline**. Once entries can be **edited**, a
silently mutable clinical record is a problem: a co-caretaker or vet reading the timeline
can't tell whether — or how — an entry changed after it was written, and an accidental or
disputed edit has no paper trail. We want edits to be **auditable**, and we want a natural
bound on churn so an entry can't be rewritten indefinitely.

Two questions follow: *what* history do we keep and who can see it, and *how much* editing
is allowed.

## Decision

**Every edit that changes a log entry records an immutable snapshot of its prior state, an
entry may be edited at most nine times, and the history is visible to anyone who can read
the entry.**

- **Revision snapshots.** Each real edit writes a `log_entry_revisions` row — a `jsonb`
  snapshot of the entry *as it stood before the edit* (its `type` + all `data` fields +
  note + `occurred_at` + `visibility`), plus who edited and when, and a denormalized
  `pet_id` for scoping. The unlisted **share token is excluded** from the snapshot (a
  snapshot must not duplicate a secret). A **no-op edit records nothing** (it changes
  nothing).
- **Nine lives.** A log may be edited **at most nine times**; the tenth edit is refused
  (a changeset/validation error, surfaced in the UI). A denormalized `edit_count` (0–9) on
  the entry makes the cap an O(1) check and lets the UI show "N of 9" and disable editing
  at the limit.
- **History visibility follows the entry.** Reading an entry's revisions uses the **same
  read authorization as reading the entry** — any effective grant, plus the private-entry
  rule (a non-owner who can't see a private entry can't see its history). It is **not**
  admin-only: everyone who can see the log can see how it changed.
- **Revisions are immutable and preserved.** They are never edited or deleted, and they
  ride the parent's soft-delete (hidden with it, reachable only via an explicit unfiltered
  query), keeping the audit trail intact.

## Consequences

- **Auditable clinical record.** Any reader can see an entry's lineage; an edit can't
  quietly alter history.
- **Bounded churn + storage.** At most nine revisions per entry caps both the edit surface
  and the history table's growth per entry.
- **Editor identity is exposed** to anyone who can read the history (a user id, like
  `recorded_by_user_id`). That is intentional transparency for shared care; it reveals no
  more than that some grant-holder edited the entry.
- **The snapshot is a point-in-time copy**, not a diff. Reconstructing "what changed" is
  left to the reader/UI comparing adjacent versions.

## Alternatives considered

- **No history (silent edits)** — simplest, but unacceptable for a clinical record.
- **Admin-only history** — the original instinct, but the people who most need to trust
  the timeline (co-caretakers, vets) aren't admins; scoping it to log-readers serves the
  actual need.
- **Unlimited edits** — no natural bound; invites indefinite rewriting and unbounded
  history growth. Nine is a deliberate, memorable cap ("a cat's nine lives").
- **A `jsonb` snapshot vs. per-column/temporal history** — a `jsonb` snapshot handles the
  one-table, `type`-discriminated log shape uniformly without replicating the schema, and
  survives schema changes better than a stored diff.
