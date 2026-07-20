# 0012. Vet access model: verified profiles and frozen health-summary reports

- **Status:** Accepted
- **Date:** 2026-07-20
- **Deciders:** GoodMao maintainers

## Context

The product's clinical value is delivered to a **veterinarian**: an owner shares a pet's
history so a professional can act on it. Two forces shaped this milestone:

1. **"Vet" must mean something.** The `pet_accesses` schema has always had a `vet` role
   (read + author `vet_note`), but any user could be handed it. The roadmap invariant is that
   a vet is an *active, verified* professional — so the role must be gated on a verified
   credential, on grant *and* on any later re-grant (the grant path doubles as an update).
2. **A vet often reads a summary once.** Beyond live timeline access, a vet needs a
   point-in-time **health summary** — printable, and shareable even with a vet who has no
   account or whose live access has ended. This raises two sub-questions the architecture
   docs left open: is the report **stored or regenerated**, and how is it shared safely?

Constraints carried in: per-entry `private` visibility (ADR-0004) must never leak; deletion is
soft (ADR-0008); every read is IDOR-hidden; the CSP forbids inline scripts.

## Decision

**Verified `VetProfile`.** We add `Accounts.VetProfile` (0..1 per user: license number,
licensing body, region, clinic, optional specialty, `verification_status`). A user submits/
resubmits on `/users/vet-profile` (a resubmission returns to `pending`); the sole
administrator verifies or rejects from `/admin`. `Pets.grant_access/3` refuses the `vet` role
with `{:error, :vet_not_verified}` unless `Accounts.verified_vet?/1` holds — checked on the
shared grant/re-grant path, so promotion to `vet` is gated too.

**Frozen health-summary reports.** We add a `Reports` context and `HealthSummaryReport` schema.
`generate_report/3` (requires `:manage`) **freezes** a `jsonb` snapshot of the pet descriptor
and the timeline over a date range. The snapshot is built from `Logs.shareable_entries/3`,
which **excludes every `private` entry regardless of the generator's role** — so an
owner-generated report can safely be shown to a vet or opened anonymously. A report is a
stored snapshot, not a live re-query.

**Sharing.** Reading requires `:read` (owner *and* vet see reports); generating, sharing, and
deleting require `:manage`. An optional **expiring** anonymous share link stores only the
SHA-256 hash of its token (raw token shown once) and is always paired with `share_expires_at`.
`ReportController` (`GET /reports/shared/:token`, `:browser` pipeline, no auth) renders the
snapshot only for an unexpired, matching, non-deleted token; anything else is `not_found`
(existence-hidden), mirroring `MediaController`. The report view is print-friendly (a CSP-safe
`Print` LiveView hook in the app; a nonce'd inline script on the anonymous page).

## Consequences

- The `vet` role now carries authority: it cannot exist without an admin-reviewed credential.
- Reports outlive live access and log edits, matching "point-in-time," and are safe to share
  because private entries are structurally absent from the snapshot (not merely hidden at view
  time).
- The weight-trend SVG chart was extracted into a shared `ReportComponents.weight_chart/1` used
  by both the live pet page and the report, so they cannot drift.
- New surfaces: a token-gated anonymous route and an admin review queue — both existence-hidden.
- Follow-ups (deferred): per-entry public share links (ADR-0004), serving life-log **media**
  inside a shared report, timeline `offset` paging for very long reports, and async report
  generation if snapshots grow large.

## Alternatives considered

- **Regenerate report content on each view** — rejected: not truly point-in-time, cannot
  outlive the reader's access, and would re-apply the viewer's (possibly owner) visibility,
  risking private-entry exposure through a shared link.
- **Filter private entries only at render time** — rejected: a single missed code path would
  leak. Excluding them at snapshot time makes the guarantee structural.
- **Gate the `vet` role in the UI only** (hide it unless verified) — rejected: the grantee is
  resolved after submit and the context is the security boundary, so the check lives in
  `Pets.grant_access/3`.
- **Store the raw share token** — rejected: store only its hash, as with auth tokens
  (`Accounts.UserToken`), so a database read cannot resurrect a live link.
