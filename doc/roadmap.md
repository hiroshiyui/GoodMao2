# GoodMao2 — Roadmap

_Last updated: 2026-07-18_

The Phoenix edition was built **depth-first from the core**: the heart of the product
(effortless structured logging → shareable, authorized timeline) ships first and fully.
This tracks what's done and what's intentionally deferred. Feature framing follows the
original [GoodMao roadmap](../../GoodMao/doc/roadmap.md).

## Vision

The classic vet-visit problem is that owners reconstruct history from memory, badly.
GoodMao makes **effortless structured daily logging** that produces a **shareable health
timeline** — the social/follower layer is not decoration, it is the delivery mechanism for
clinical value.

**One-line pitch:** effortless structured daily logging that produces a shareable health
timeline vets can actually use.

GoodMao is for pets people love, and sometimes grieve. The product should be
**thoughtful, gracious, and affable** throughout — meeting people with warmth, never
rushing a heavy moment, and letting them record the truth of their situation. This is why
end-of-care preserves the record and its date is backdatable ([ADR-0003](adr/0003-pet-lifecycle.md)),
and why error copy stays honest without leaking ([ADR-0007](adr/0007-error-reporting.md)).

## Core principle: structured logging

Free-text ("seemed off today 😟") is clinically useless. The heart of the product is
**structured, one-tap log entries** that a vet can act on. If logging is not effortless,
nobody logs consistently — and inconsistent logs make the vet feature worthless. Free-text
notes exist *alongside* structured fields, never instead of them.

The high-signal, low-effort daily log types carry real clinical domain knowledge — see the
per-type `data` fields in [`architecture.md`](architecture.md):

- Food intake (full / partial / **refused**)
- Water intake (normal / low / high)
- Bathroom (frequency + abnormalities — **urinary blockages in cats are emergencies**, so
  a `bathroom` entry carries an `is_straining` signal)
- Vomiting / diarrhea episodes (count)
- Weight (periodic, in the pet's `weight_unit`)
- Energy / mood (1–5 scale)
- Medication given (timestamped — ties to multi-caretaker coordination)

## Vet access model (both planned)

1. **Time-boxed live access** — an owner grants a vet temporary read access to the pet's
   live timeline for a visit ("share history with Dr. Lin"). The `pet_accesses` grant with
   an `expires_at` already supports this; the vet-facing UI is Phase 4.
2. **Health summary report** — a generated, point-in-time summary the vet reads once (also
   useful for export / print). Deferred — see the deferred entities in
   [`architecture.md`](architecture.md).

Vets are **active, verified users** (professional credential verification), so their input
carries authority rather than being anonymous advice.

## Shipped — MVP core

- [x] Scope-based auth (`phx.gen.auth`), first user → administrator, editable `@handle`
- [x] Pets: create / list / view / edit, coat colour, weight unit
- [x] Owner-only end-of-care lifecycle (status transition, backdatable `ended_at`, reversible)
- [x] `history_hidden` opt-in flag (schema + changeset)
- [x] Resource-based per-pet authorization (`owner` / `co_caretaker` / `viewer` / `vet`,
      capability levels, time-boxed grants, ≥1-owner invariant, IDOR-hidden 404s)
- [x] Grant / revoke access by `@handle` or email (Sharing page)
- [x] Structured log entries (single table + `type` + `jsonb`), per-type validation
- [x] One-tap QuickLog (food / water / bathroom / vomit / weight / energy / medication / symptom)
- [x] Backdatable `occurred_at`, free-text note, per-entry `visibility` (owner-only change)
- [x] Vet-authored `vet_note` entries (vet-only)
- [x] Live, type-filterable timeline via Phoenix PubSub
- [x] Soft-delete of entries (`deleted_at`)
- [x] Gettext throughout; `en` populated, `zh_TW` / `ja_JP` scaffolded
- [x] Test suite (context + LiveView) and `mix precommit` gate; dev seed data

## Deferred (mapped to the original's later phases)

- [ ] Weight / trend charts (Phase 1)
- [ ] Medication schedules + reminders; the "did anyone give the pill?" coordination (Phase 1/3)
- [ ] LifeLog media (photos/videos) with EXIF-stripping purification — the `image` lib +
      `life` type is scaffolded ([ADR-0005](adr/0005-media-storage.md); Phase 1)
- [ ] **Oban** for background jobs (janitor, reminders, async media, notification fan-out)
      — deferred until a job actually needs it (supersedes the original's ADR-0006; Phase 1/2)
- [ ] Log **edit revisions** audit trail + edit-count cap ([ADR-0009](adr/0009-log-edit-revisions.md); Phase 1)
- [ ] In-site **notification feed** + 1:1 **mailbox**, live unread badges via PubSub
      ([ADR-0011](adr/0011-notifications-and-messaging.md); Phase 3)
- [ ] Per-entry **share links** (public token) + anonymous shared timeline/media
      ([ADR-0004](adr/0004-log-visibility.md); Phase 3)
- [ ] Verified **veterinarian accounts** (credential verification) + generated
      **health-summary report** export (Phase 4)
- [ ] Trilingual translations populated for `zh_TW` / `ja_JP` + footer language switcher
- [ ] Full localization of the `phx.gen.auth` LiveViews (login/register/settings still
      carry some generator-default English)

## Notes / follow-ups

- User references that are audit-only (`recorded_by_user_id`, `granted_by_user_id`,
  `created_by_user_id`) are stored without FK navigations, mirroring the original's
  cascade-path decision.
- The `life` log type and `visibility` `public` + share-token concept are modeled in the
  schema but their UI/endpoints are deferred with the media and share-link work above.
