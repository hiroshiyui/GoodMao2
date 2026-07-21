# 19. Medication schedules, materialized doses, and reminders

- **Status:** Accepted _(shipped)_
- **Date:** 2026-07-21
- **Deciders:** GoodMao maintainers

> _Shipped: recurring medication schedules; durable, per-slot dose rows any caretaker can claim;
> a one-tap "Give" that reuses the `medication` timeline entry; and `medication_due` bell + Web
> Push reminders fired at the schedule's local time by an Oban cron._

## Context

Medication is the sharpest multi-caretaker coordination problem: **"did anyone already give the
8pm pill?"** Today `medication` is only a point-in-time `log_entry` ("a dose was given") — there
is no plan, no notion of a dose being *due*, and nothing to stop two caretakers double-dosing or
everyone assuming someone else did it. The maintainers want recurring **schedules**, a clear
**is-this-dose-done** signal shared across caretakers, and **reminders** when a dose is due or
overdue — at the right *local* time (now possible with per-viewer timezones, ADR-0018).

Constraints carried in: authorization is resource-based and per-request (ADR-0014); deletion is
soft (ADR-0008); notifications render copy at read time and fan out bell + Web Push through one
choke point (ADR-0011); times are stored UTC and localized at the edges (ADR-0018).

## Decision

**Add a `Medications` context with recurring schedules and *materialized* dose slots. Marking a
dose given reuses the `medication` log type. Reminders fan out a new `medication_due`
notification from an Oban cron, computed in each schedule's own timezone.**

- **Schedule + materialized doses.** A `medication_schedules` row carries the plan
  (medication, dose, `times_of_day`, `interval_days`, start/end, `active`, `notes`) and its own
  **IANA `timezone`** — "8am" is the pet's local 8am, shared across caretakers in different
  zones. `Medications.materialize_doses/1` pre-creates one durable `medication_doses` row per
  upcoming slot (converting each wall-clock time in `timezone` to a UTC `due_at`, DST-safe via
  `Goodmao2.Timezone`), idempotent through a unique `(schedule_id, due_at)` index. A row per slot
  — not an on-the-fly computation — is what makes "this specific dose is handled, by Ada, at
  8:03" a durable, shareable fact.

- **Claiming a dose is atomic (no double-dose).** `mark_dose_given/4` runs an atomic
  `pending → given` `UPDATE … WHERE status = 'pending'` inside a transaction; a second caretaker
  racing the same slot updates zero rows and gets `{:error, :already_recorded}`. On a successful
  claim it **reuses `Logs.create_entry/3`** to write a normal `medication` timeline entry — one
  history, not a parallel one — and stamps `given_at` / `recorded_by_user_id` / `log_entry_id`
  together with the claim. `mark_dose_skipped/3` claims the slot without a log entry.

- **Reminders via cron + one new type.** `Medications.ReminderWorker` (Oban, every 15 min)
  keeps the rolling horizon filled, ages overdue pending slots to `missed`, and calls
  `dispatch_due_reminders/0`, which sends a **`medication_due`** notification for each pending,
  now-due slot and stamps `reminded_at` so it nudges **once**, not every tick. Recipients are the
  pet's **effective caretakers who can write** (owner / co-caretaker / vet). Bell + Web Push ride
  the existing `Notifications.create/3` choke point for free; the copy renders at read time.

- **Authorization.** Reading schedules/doses needs `:read` (existence-hidden otherwise);
  creating/editing a schedule and marking a dose given/skipped need **`:write`** (owner,
  co-caretaker, vet — the people who administer meds); **deleting** a schedule needs `:manage`
  (owner). Deleting soft-deletes and cancels future pending doses.

- **Web surface.** `PetLive.Medications` (`/pets/:pet_id/medications`, linked from the pet page)
  lists schedules with a create form and a **live doses-due checklist** (one-tap Give / Skip,
  showing who gave each dose and when), refreshed over the pet's PubSub topic.

## Consequences

- **The coordination question is answered directly**: the checklist shows each due dose and, once
  claimed, who handled it — live for every caretaker — and reminders stop nagging once a dose is
  recorded.
- **One timeline, not two.** A given dose is an ordinary `medication` entry, so reports, the
  timeline, and clinical flags see it with zero special-casing.
- **Dose rows accumulate.** Materialization creates a row per slot; the horizon is bounded (48h)
  and the cron fills it forward, but historical doses persist (they are the record). A future
  retention janitor could prune very old terminal doses (ADR-0008 permits GC of processed rows).
- **Correctness leans on two atomic guards**: the unique `(schedule_id, due_at)` index (no
  duplicate slots) and the `WHERE status = 'pending'` claim (no double-record). Any new path that
  mutates a dose must preserve them.
- **Reminders are best-effort and coarse** (a 15-min cron, a single nudge per slot, a 2h "missed"
  grace). Finer timing, snooze, or escalation are deferred.
- **Per-schedule timezone**, not per-pet — a schedule created in one zone keeps firing there even
  if a caretaker travels; editing the schedule's zone is the escape hatch.

## Alternatives considered

- **Compute dose slots on the fly** (no `medication_doses` table) — rejected: there would be
  nowhere durable to record *who* gave *which* slot and *when*, which is the whole coordination
  point; and reminders would need a separate "already reminded / already given" store anyway.
- **A separate medication-dose history instead of reusing `medication` logs** — rejected: it
  would split the timeline and force every reader (reports, flags, calendar) to merge two
  sources. Reusing the log type keeps one history.
- **Optimistic claim without the atomic guard** (read-then-write) — rejected: it is precisely the
  double-dose race the feature exists to prevent; the single guarded `UPDATE` is both simpler and
  correct.
- **Bespoke reminder scheduling instead of a periodic sweep** — rejected: a 15-min cron over
  materialized slots is simple, restart-safe, and rides the existing Oban setup; per-dose
  scheduled jobs add moving parts for no user-visible gain at this granularity.
- **Store dose times as UTC** — rejected: caretakers think in the pet's local time; a per-schedule
  IANA zone keeps "8pm" meaning 8pm across DST and across caretakers' own zones (ADR-0018).
