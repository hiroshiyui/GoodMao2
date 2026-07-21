# 15. Structured logging in one table with a typed JSONB payload

- **Status:** Accepted _(shipped; foundational — recorded retroactively)_
- **Date:** 2026-07-21
- **Deciders:** GoodMao maintainers

> _The product's core principle (roadmap §1), in place since the MVP core. Recorded now so
> the data-model decision behind every log type is written down, not just implied by
> `Logs.LogEntry`._

## Context

GoodMao's whole value proposition is that daily logging is **structured, not free-text**.
"Seemed off today 😟" is clinically useless; "refused food, 2× vomiting, straining in the
litter box" is a vet-actionable signal. So the log has to capture **strongly-typed,
per-kind fields** — food amount, water level, bathroom kind + blood/straining flags, weight
in grams, energy 1–5, medication name + dose, symptom + severity, vet assessment — while
still being **one-tap** to record.

That pulls in two directions:

1. **Each type has its own shape.** A weight entry and a bathroom entry share almost no
   fields. Modelled naïvely, that is one table per type.
2. **The timeline is one stream.** The product surface is a single chronological,
   type-filterable timeline (and a calendar), with cross-type clinical queries ("weight
   trend", "vomiting this week", "was the pill given?"). Many tables make that a pile of
   `UNION`s and per-type join logic on the hottest read path.

There is also a soft constraint: species-specific and future extras should be able to ride
along **without a migration per variant**, so the schema doesn't churn every time a new
signal is added.

## Decision

**Every log entry lives in one `log_entries` table. A `type` string is the discriminator;
the type-specific structured fields live in a `jsonb` `data` map validated per type in the
changeset. Free-text `note` sits alongside the structured fields, never instead of them.**

- **One table, one discriminator.** `log_entries` carries the common columns —
  `pet_id`, `type`, `occurred_at`, `note`, `visibility`, `data` (jsonb), `deleted_at`,
  `edit_count`, timestamps, `recorded_by_user_id` — for all ten types
  (`food water bathroom vomit weight energy medication symptom vet_note life`). The
  timeline is a single `WHERE pet_id = … AND deleted_at IS NULL ORDER BY occurred_at`
  query with an optional `type` filter — no unions, no per-type joins.

- **Typed payload in `data`.** `LogEntry.changeset/2` validates the common fields, then
  dispatches on `type` to a **per-type spec** (`@specs`) declaring required/optional
  enum, string, number, and boolean fields. `sanitize/2` coerces values, enforces enum
  membership and required presence, caps string length, and **drops unknown keys** — so the
  stored `data` is always a clean, known shape. An invalid type-specific field is a
  changeset error on `:data`, exactly like a column validation.

- **Structured *and* free-text.** `note` is a first-class column available to every type,
  but it is additive: `food` still requires an `amount` enum, `weight` still requires
  `weight_grams`, etc. The one exception is `life` (a daily-life note), whose content *is*
  its caption — so a `life` entry requires `note` until media enrichment lands
  ([ADR-0005](0005-media-storage.md)).

- **Clinical semantics live in the spec, not the caller.** Domain knowledge — a cat
  straining in the litter box is an emergency, so `bathroom` carries `has_blood` /
  `straining` booleans; food can be `refused`; energy is a 1–5 scale — is encoded once in
  `@specs` and surfaced by shared helpers (clinical-flag chips, calendar cues), so the UI
  and the data can't drift.

- **`data` is not a security or visibility boundary.** Authorization
  ([ADR-0014](0014-resource-based-authorization.md)), per-entry visibility
  ([ADR-0004](0004-log-visibility.md)), and soft-delete ([ADR-0008](0008-soft-delete.md))
  are all columns/context rules on the row, never fields inside `data`.

## Consequences

- **The timeline stays a single, fast, filterable stream.** Cross-type reads (trend
  charts, weekly counts, calendar aggregates) are ordinary queries over one table; adding a
  filter or a new aggregate needs no schema change.
- **A new log type is mostly a new `@specs` entry** plus its QuickLog affordance and
  translations — no migration, no new table, no new read path.
- **The changeset is the schema for `data`.** Postgres does not enforce the payload shape,
  so `LogEntry.changeset/2` is load-bearing: any write path that bypasses it can store a
  malformed `data`. All writes go through the context, and the sanitizer drops unknown keys
  so stray input can't accumulate.
- **`jsonb` fields aren't free to query relationally.** Heavy analytics on a specific
  payload field (e.g. indexed medication-name search) may later warrant a generated column
  or an expression index; that is an additive optimization, not a remodel.
- **Per-type validation must stay in sync with the UI.** The QuickLog buttons and the
  manual form are generated around the same type set / spec, so the affordances and the
  validation cannot disagree; `quicklog_types/1` also gates the vet-only `vet_note` as
  defence in depth over the context check.

## Alternatives considered

- **One table per log type** (`food_logs`, `weight_logs`, …) — rejected: the timeline
  becomes a fan of `UNION`s, every cross-type feature grows per-table code, and each new
  signal is a migration. The read path is the product; it must stay simple.
- **Single-table inheritance with a wide, sparse column set** (a nullable column per
  possible field) — rejected: the table grows a column per field of every type, most rows
  are mostly NULL, and adding a field still means a migration. `jsonb` keeps the row narrow
  and the shape per-type.
- **Untyped free-text notes only** — rejected outright: this is the exact clinical failure
  the product exists to fix; structured fields are the point.
- **Enforce the payload shape with a Postgres JSON schema / `CHECK` constraint** — rejected
  as the primary guard: the per-type rules (enums, coercion, required-by-type, length caps,
  unknown-key stripping) are far more naturally and testably expressed in the changeset,
  which every write already passes through.
