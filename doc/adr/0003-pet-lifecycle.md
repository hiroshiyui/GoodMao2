# 3. Pet lifecycle: end-of-care is a status transition, not a deletion

- **Status:** Accepted _(shipped)_
- **Date:** 2026-07-10
- **Deciders:** GoodMao maintainers

## Context

A pet is not a disposable record — it has a **whole life** in the app: it is
*active* under care, and eventually reaches an **end of care** (it passes away, is
rehomed, is lost, or leaves for some other reason). The everyday logs owners keep
become a **clinical timeline** (see [`../roadmap.md`](../roadmap.md)); for a pet
that has passed away, that timeline is both a **medical record** (a co-caretaker or
vet may still need to read or annotate it) and something with **sentimental value**
to the household.

A naive design would model removal as a **delete** (or a hide-everything
soft-delete), which conflates two different ideas: "this pet is no longer under active
care" and "make this pet's history disappear." It also silently freezes a record the
owner may want to keep reading, and offers no vocabulary for *why* the pet left.

We need a model that treats end-of-care as a first-class part of the pet's
lifecycle, preserves the record by default, and still lets an owner choose privacy.

## Decision

**We model a pet's lifecycle as a first-class status, and treat end-of-care as a
status transition that preserves the record — never a deletion.**

- **Lifecycle status.** `pets` carries a single `lifecycle_status`
  (`active | passed_away | rehomed | lost | other`, default `active`) plus an
  `ended_at` timestamp set when it leaves `active`. The status *is* the reason —
  there is no separate reason field.
- **End-of-care is an owner-only transition,** not a delete. The `PetLive.EndOfCare`
  LiveView (authorized in `mount` via `Pets.fetch_pet/3` requiring `:manage`) sets
  `lifecycle_status` + `ended_at`. It rejects a transition back to `active` (that is not
  an end state). The pet row and its `log_entries` are never removed.
- **The end date is the owner's to set — and it is backdatable.** The transition
  accepts an optional `ended_at` (defaulting to now, never in the future). A grieving
  owner rarely records a death the day it happens, and an owner may add a pet that
  left the household long ago; stamping "today" would be both inaccurate and unkind.
  We let them enter the real date. This mirrors the backdating we already allow on log
  entries (`occurred_at`), and embodies the project's "be gracious to people" principle.
- **Ended pets stay viewable.** They drop out of the owner's **active** pet list
  (`PetLive.Index` separates active from past pets) but remain reachable — the detail
  page and the full timeline still load for anyone with an effective grant.
- **Logging is still allowed after end-of-care** (a vet's final assessment, a
  correction). Ending a pet does not freeze its timeline.
- **Privacy is a separate, explicit choice.** A `history_hidden` flag
  (owner-only, reversible) fully hides the timeline, consistent with our
  existence-hiding IDOR convention (an inaccessible timeline is `not_found`, never
  "forbidden"). This is orthogonal to lifecycle status: hiding is opt-in and does not
  happen automatically on end-of-care.

## Consequences

- The clinical record survives the pet — history is preserved for reading and
  annotation, honoring the "structured logging is the core" principle even after a
  pet passes away.
- The UI can show *why* a pet left (a "Passed away · <date>" banner) and keep
  memorial pets out of the day-to-day list without losing them (the **Past pets**
  section of `PetLive.Index`).
- Owners get a clear, reversible privacy control (`history_hidden`) decoupled from
  the emotional act of recording that a pet has died or moved on.
- **Follow-up / not built now:** reactivating a pet (e.g. a *lost* pet found) is a
  natural transition back to `active` but has no path yet. A future ADR may revisit it.

## Alternatives considered

- **Hard delete** — removing the pet and cascading its logs. Destroys an
  irreplaceable clinical + sentimental record and breaks any shared timeline a vet
  or co-caretaker relied on. Rejected outright.
- **Soft-delete / hide-by-default** — hides the pet and all its logs. Preserves the
  row but makes the record unreadable exactly when its history matters, and cannot
  express *why* the pet left. Rejected in favor of default-viewable + an explicit
  opt-in hide (`history_hidden`).
- **Freeze logging on end-of-care** — blocking writes once a pet is ended. Prevents
  legitimate final notes (post-mortem vet assessment, a late correction) and adds a
  second axis of "archived-ness" the model does not need. Rejected; logging stays
  open and privacy is handled by the separate `history_hidden` flag.
