# Architecture Decision Records

This directory records **Architecture Decision Records (ADRs)** — short documents
that capture a significant technical or architectural decision, the context that
forced it, and the consequences of choosing it.

An ADR is worth writing when a decision is **hard to reverse, cross-cutting, or
likely to be questioned later** — e.g. a framework/library choice, an auth model,
a data-modelling trade-off, or a locale/formatting policy. Routine, easily-reversed
choices do not need one.

See also [`../roadmap.md`](../roadmap.md) for product vision and scope,
[`../architecture.md`](../architecture.md) for the current design, and
[`../../CLAUDE.md`](../../CLAUDE.md) / [`../../AGENTS.md`](../../AGENTS.md) for the
decided stack and the invariants to preserve.

## Provenance

These are GoodMao's own architecture decision records. Each file keeps a stable number and
decision date, and its `Status` reflects what GoodMao has actually shipped vs. deferred.

Two numbers are **intentionally skipped**, because their decision does not apply to a
Phoenix monolith — the gaps keep the surviving cross-references (e.g. ADR-0004 → ADR-0003)
valid:

- **ADR-0006 (durable background-job queue)** — *superseded by Oban.* GoodMao will use
  [Oban](https://hexdocs.pm/oban) (retry/backoff/uniqueness/cron out of the box) when a
  job first needs it, rather than a bespoke queue.
- **ADR-0010 (self-hosted inline SVG icons)** — *not applicable.* GoodMao uses Phoenix's
  built-in `<.icon>` hero-icons; the general "self-host, no CDN on the render path"
  principle is already covered by the project's asset-bundling rules.

## Conventions

- **One decision per file**, named `NNNN-kebab-case-title.md` (zero-padded). Numbers are
  sequential and never reused.
- Copy [`0000-template.md`](0000-template.md) to start a new record.
- **Status lifecycle:** `Proposed` → `Accepted` → (later) `Deprecated` or
  `Superseded by ADR-NNNN`. Do not edit the decision of an accepted ADR in place;
  supersede it with a new ADR and link the two.
- Keep them short (one page). Link related ADRs and design docs.

## Index

| ADR | Title | Status |
| --- | ----- | ------ |
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted |
| [0002](0002-culture-first-localization.md) | Culture-first localization: name & tagline policy | Accepted |
| [0003](0003-pet-lifecycle.md) | Pet lifecycle: end-of-care is a status transition, not a deletion | Accepted |
| [0004](0004-log-visibility.md) | Log-entry visibility scopes | Accepted (schema; UI deferred) |
| [0005](0005-media-storage.md) | Purified media for life logs | Proposed (deferred) |
| ~~0006~~ | ~~Durable background-job queue~~ | Superseded by Oban |
| [0007](0007-error-reporting.md) | Explicit error reporting without exposing sensitive information | Accepted |
| [0008](0008-soft-delete.md) | Deletion is always soft — never a permanent removal | Accepted |
| [0009](0009-log-edit-revisions.md) | Log-entry edit history, capped at nine edits | Proposed (deferred) |
| ~~0010~~ | ~~Self-hosted inline SVG icons~~ | Not applicable (Phoenix hero-icons) |
| [0011](0011-notifications-and-messaging.md) | In-site notifications and a private mailbox | Accepted (Stage 1 + Web Push Stage 2 shipped) |
| [0012](0012-vet-access-model.md) | Vet access model: verified profiles and frozen health-summary reports | Accepted |
| [0013](0013-second-factor-authentication.md) | Second-factor authentication (TOTP + WebAuthn/FIDO2) | Accepted (shipped) |
| [0014](0014-resource-based-authorization.md) | Resource-based per-pet authorization | Accepted (shipped) |
| [0015](0015-structured-one-table-logging.md) | Structured logging in one table with a typed JSONB payload | Accepted (shipped) |
| [0016](0016-scope-based-auth-and-first-user-admin.md) | Scope-based authentication and a single first-user administrator | Accepted (shipped) |
| [0017](0017-rust-nif-native-boundary.md) | A Rust/Rustler native boundary for CPU-bound work | Accepted (scaffolding) |

_Add a row per ADR as it lands._

_ADRs 0014–0017 are **retroactive records** of foundational decisions that shipped with
the MVP core; they were written down after the fact so the invariants they define are
documented, not merely implied by the code._
