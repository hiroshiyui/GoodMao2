# Web Application Development — Common Practices

Product-agnostic engineering and operational practices, distilled from real development
history on GoodMao and carried into GoodMao2. Each practice is stated generally, with the
failure mode that motivates it — the reasoning matters more than the rule.

> **Provenance.** Ported from GoodMao's
> [`web-application-development-common-practices.md`](../../GoodMao/doc/web-application-development-common-practices.md).
> GoodMao was a decoupled two-tier app (SvelteKit BFF + ASP.NET Core API); GoodMao2 is a
> **Phoenix/LiveView monolith**. The two-tier-only lessons (a machine-checked API contract
> as a build artifact, a BFF cookie relay, cross-tier string ownership) are dropped or
> folded in; everything else applies directly, re-flavored for Phoenix/Ecto/Gettext.
> Where a practice is already enforced in this repo, it is cross-referenced.

## 1. Architecture and boundaries

- **Keep the web layer thin; put the domain in contexts.** LiveViews authorize and render;
  the real work — authorization, validation, invariants — lives in `Accounts`/`Pets`/`Logs`
  and is called from the web layer. One place to audit, one place to test.
- **Re-check at the context boundary, not only in the caller.** A rule enforced only in a
  LiveView is one refactor away from being bypassed by another entry point (a task, a
  test, a second LiveView). The context is the boundary that must hold.
- **A monolith is not an excuse to skip seams.** Inject the clock, route background work
  through a queue interface, keep PubSub topics explicit — the seams that make a two-tier
  app testable make a monolith testable too (see §9).

## 2. Security: design it in, then test both directions

- **Resource-based authorization, not global roles.** Resolve the caller's effective grant
  for the specific resource through one shared function (`Pets.can?/3`); even an admin role
  gets no backdoor to resource data. One authorization code path means one place to audit
  and one place to fix.
- **Hide existence: no grant → `not_found`, never "forbidden".** Set the convention at the
  first resource surface (`Pets.fetch_pet/3`) and let every later one inherit it.
  Consistency is the defense — a single "forbidden" where "not found" belongs leaks that
  the resource exists (IDOR).
- **Enforce invariants on _every_ mutation path, not just the obvious one.** A gate applied
  at create is routinely missing from the update written later; a "last owner" guard that
  checks role downgrades can be bypassed by back-dating an expiry. An invariant belongs to
  the model's rules — audit each function that can move the state.
- **Re-check authorization on every action, not only at relationship creation.** State
  (revocations, expiries, privacy settings) changes mid-session: a grant checked only when
  a conversation _starts_ lets a since-revoked user keep posting into the existing thread;
  a delete authorized against stale UI state instead of the record's real parent is a
  confused deputy.
- **Never trust client-supplied structure.** Validate enum strings against the known option
  set before casting; ignore over-posted, server-owned fields on create; scope cross-entity
  references to the parent resource (a child record must not reference another owner's row);
  parse client-supplied IDs safely so a forged id yields an error, not a crash. Ecto
  changesets with explicit `cast`/`validate_inclusion` are the tool.
- **Purify uploads; never store user bytes as-is.** Sniff content type from magic bytes
  (ignore the client header), reject active content (e.g. SVG), re-encode images to strip
  EXIF/GPS and polyglot payloads, remux videos to drop metadata and unexpected streams.
  Store under an opaque, generated path that is never persisted — traversal-proof by
  construction — and serve bytes only through an authorized endpoint that re-applies the
  parent's read rules. See [ADR-0005](adr/0005-media-storage.md).
- **Close bootstrap races.** "First registered user becomes admin" is a race an attacker
  can win on a fresh deploy. Pin first-run setup to a configured owner identity or a
  one-time key, checked **before** anything is persisted. Any "first one wins" rule needs a
  pin — and a deterministic test fixture (§9).
- **A signature proves who _sent_ something, not that the _subject_ consented.** Operations
  acting on behalf of a third party (delegation, account migration) must verify the target
  agreed, not just authenticate the sender.
- **SSRF defense is layered.** Any user-supplied URL fetched server-side (link previews,
  webhooks, Web Push endpoints — see [ADR-0011](adr/0011-notifications-and-messaging.md))
  needs a private-range denylist that also catches IPv6 embeddings (NAT64, IPv4-in-IPv6)
  and reserved ranges. The endgame: force _every_ outbound request through one SSRF-safe
  client that pins the resolved DNS answer onto the connection (defeating DNS rebinding).
- **One sanitization gate for untrusted HTML, held constant across refactors.** Centralize
  it with explicit allowlists (strict for remote content, permissive for local markup);
  when you swap the renderer, the sanitizer stays the unchanged security boundary. Prefer
  the platform's html-safe serialization (HEEx auto-escapes) over hand-rolled escaping,
  which misses the parser's obscure states (`<!--<script` double-escaping).
- **Replace unmaintained dependencies with unpatched CVEs — don't pin around them.** Run
  `mix hex.audit` / `mix deps.audit` as a routine gate, not a crisis response, and
  distinguish shipped exposure from test-only exposure when triaging (the `check-updates`
  and `security-audit` skills).
- **Honor proxy headers only from trusted proxies.** A forwarded client-IP header is
  attacker-controlled unless the immediate peer is on an allow-list — and any rate limiting
  keyed on client IP is only as strong as this check.
- **Reserve identifiers on deletion** so a deleted account or handle can't be re-registered
  by an impersonator.
- **Secrets never live in committed config.** Connection strings, storage roots, owner
  identities, VAPID/API keys — anything that differs per deployment or must not leak comes
  from `runtime.exs` reading the environment (or a secret store), never a checked-in file.
- **Follow current guidance over folklore.** Password policy: length over composition rules
  (NIST 800-63B) so passphrases are accepted; progressive login delay over hard lockout
  (an account-DoS vector). Cookie hardening (HttpOnly, Secure, SameSite) and rate limiting
  on auth endpoints from day one.

## 3. Data modeling: model reality, don't delete it

- **Prefer lifecycle status over deletion.** An "archive/soft-delete" is usually a real
  domain state in disguise (closed, ended, retired). Modeling it explicitly preserves the
  record and its history, changes listing behavior deliberately, and keeps orthogonal
  concerns (e.g. hiding history) as their own flags rather than conflated with "deleted".
  See [ADR-0003](adr/0003-pet-lifecycle.md) and [ADR-0008](adr/0008-soft-delete.md).
- **Separate visibility from access.** Grants say _who_ may read; a per-record visibility
  scope further narrows _what_ they see. Public exposure goes through an unlisted,
  revocable token — never by loosening the grant-gated reads. See
  [ADR-0004](adr/0004-log-visibility.md).
- **Denormalize the authorization anchor.** Give dependent records (media assets, revisions)
  a direct `pet_id` reference to the resource authorization is decided on, so the check
  doesn't depend on joining through mutable intermediate rows.
- **Keep reads honest.** Give every timestamp-ordered query a unique-id tiebreaker —
  colliding timestamps otherwise make pagination and the live timeline non-deterministic.
- **Validate for domain meaning, not just type-safety.** Range-check domain-significant
  fields (a 1–5 energy scale, non-negative quantities) in the changeset so the data stays
  _meaningful_, not merely well-typed.
- **Stamp derived identifiers in the same transaction as the insert.** A canonical id
  written in a separate post-commit update leaves permanently broken rows when a crash hits
  the gap — which is exactly why creating a pet inserts the creator's `owner` grant in the
  **same** `Ecto.Multi`. Every invariant added after data exists also needs a backfill for
  the rows written before it.
- **Back every uniqueness check with a DB unique index plus a conflict strategy.**
  Check-then-insert races with itself; application-level checks are advisory, the database
  is the arbiter (`unique_constraint` + a real index — e.g. the `citext` handle, the
  `(pet_id, user_id)` grant).

## 4. i18n: parity by test, culture over transliteration

- **Enforce catalog parity.** A message added to one locale but forgotten in another is the
  most common i18n drift; keep `en` / `zh_TW` / `ja_JP` in sync and treat a missing/fuzzy
  translation as a defect. Run `mix gettext.extract && mix gettext.merge priv/gettext`
  after any copy change.
- **Localize to the culture, don't transliterate.** Brand names, metaphors, and domain
  terms are chosen per culture — a coined name in one script can be unreadable in another.
  See [ADR-0002](adr/0002-culture-first-localization.md).
- **Wrapping a string in `gettext()` is not the same as translating it.** Extraction/merge
  and fuzzy-marker hygiene are separate steps that silently fail — audit for raw
  source-language text reaching users.
- **Ship i18n from the scaffold, and audit for stragglers.** Hardcoded strings on the
  _first_ screens a user hits (shell, auth pages) hurt most — including `aria-label`s,
  which leak untranslated text to screen readers. (The generator-default auth LiveViews
  still carry some English — see the roadmap.)
- **State established during the first render must survive the live connect.** LiveView
  renders twice — the initial HTTP dead render, then the connected socket. Anything derived
  per-request, **locale especially**, must be derived in both, or users see a first paint in
  one language that flips on connect.

## 5. Performance at scale

- **Collapse per-item queries.** N separate counts become one query with subqueries; a
  per-row lookup in a render loop becomes one preload/batch query. The N+1 you don't notice
  at 10 rows owns you at 10,000. Use Ecto `preload` and `Repo.aggregate` deliberately.
- **Denormalize aggregates you sort by; index for the query you actually run.** A
  JOIN + GROUP BY + MAX ordering becomes a maintained `last_activity_at` column; a partial
  index matching the filter every query applies (`WHERE deleted_at IS NULL`) avoids
  soft-delete bloat.
- **Cache hot cross-cutting decisions in memory — and budget for the test cost.** An
  in-memory cache (e.g. effective-grant resolution) that removes a per-request DB hit will
  become the top source of flaky tests, because global cache state survives the per-test DB
  sandbox rollback. Decide the test-isolation/reset strategy at the same time as the cache.
- **Paginate every unbounded query.** Unbounded lists (and unbounded PubSub streams) are a
  DoS surface, not just slow.

## 6. Stateful / real-time UI

- **Preserve user input across validation round-trips and reconnects.** Losing a
  half-written draft to a background-tab LiveView reconnect is a bug users remember. Keep
  form state in assigns.
- **Shared real-time infrastructure must be safe for every consumer.** A PubSub broadcast
  can deliver a message into any subscribed LiveView; every subscriber needs a catch-all
  `handle_info/2`, and the invariant belongs in the project's written rules so it can't
  regress silently.
- **Anchor DOM-dependent JS to the framework's lifecycle, never timers.** A `setTimeout`
  that races a server round-trip works in dev and silently breaks under production latency;
  use LiveView hooks' mounted/updated callbacks.
- **Degrade gracefully.** Forms should work as plain POSTs without JS (progressive
  enhancement); a transient error should degrade a region, not 500 the whole page.

## 7. Testing: real infrastructure, both sides of every gate

- **Integration-test against a real database.** Context tests (`DataCase`) and LiveView
  tests (`ConnCase`) run against a real, auto-created/migrated Postgres. Mocked databases
  don't catch migration, collation, or query-translation bugs.
- **Test both directions of every security gate.** Reject-cases alone are not enough:
  without the _positive_ case, a refactor can silently turn a gate into always-reject (or
  always-allow) without a test failing.
- **Every fix ships its regression test, in the same commit.** The test encodes the exploit
  or failure scenario so it can't quietly return.
- **Write negative-path security tests even when the code is already correct** — oversize
  payloads rejected, expired grants refused, revoked-party denials, `not_found` for an
  inaccessible pet — they exist to catch the regression.
- **Make fixtures deterministic against global state.** When behavior depends on global
  order ("first user becomes admin"), the test must pin it (register its own first user)
  rather than rely on ordering luck. Global state that survives the DB sandbox (caches,
  rate-limit buckets) must be reset or isolated explicitly.
- **Put a seam in front of stateful infrastructure.** Inject the clock; force background
  jobs (Oban) inline under test so they don't race the test transaction.
- **Keep the suite deterministic and parallel-safe by rule**: fixed seed, no sleep-based
  ordering, explicit timestamps in fixtures. When a failure appears after a change, bisect
  before blaming the change — "new" failures are often pre-existing ones a skipped suite had
  been masking.
- **Verify behavioral claims before committing, and say how.** Responsive layout at concrete
  widths; i18n by rendering each locale; a live flow by driving the LiveView. A commit that
  states its verification is a commit the next reader can trust.

## 8. Documentation: decisions are code too

- **Record cross-cutting decisions as ADRs, at decision time.** The reasoning must live
  somewhere more discoverable than commit messages and memory; every architectural turn
  gets its ADR in the same change set. See [`adr/`](adr/).
- **Sync design docs in the same change set as the code** — and when a sweep misses
  something, follow up explicitly. A design doc that contradicts the code is worse than
  none. (The `docs-engineering` skill exists for this.)
- **Write down what you deliberately did _not_ build.** Keep a deferred/follow-ups list,
  each item linked to the decision that scoped it out. Scope cut silently is scope
  forgotten — that is what the roadmap's "Deferred" section is for.
- **Stale comments are bugs.** A comment referencing a nonexistent field actively
  misdirects the next reader; fix it with the same seriousness as code.
- **Split docs by audience, not by size**: how it's designed (architecture), the shared
  vocabulary (glossary), why the turns were taken (ADRs), what's next (roadmap — with
  finished items pruned so it stays a live list, not a graveyard).
- **After every hard-won fix, write the invariant into the standing instructions**
  (`CLAUDE.md` / `AGENTS.md`). The fix prevents this regression; the documented rule
  prevents the whole class.

## 9. Release engineering and operations

- **Keep a Changelog + SemVer, from early.** Prose entries grouped Added/Changed/Fixed that
  restate the failure and the fix; the version string lives in exactly one file and must
  match the git tag. (The `release-engineering` skill executes this.)
- **A single `precommit` gate for humans and agents alike** — `mix precommit`
  (compile with warnings-as-errors + unused-deps check + format + full tests). Never push a
  red tree.
- **Periodic project-wide audit sweeps, not only reactive fixes.** Schedule hardening passes
  across security, performance, and testing (the `security-audit`/`code-review` skills);
  entropy accumulates regardless of discipline.
- **A `/health`-style readiness check that touches the DB, from day one** — the hook every
  later deploy and monitoring practice hangs off.
- **Fail fast on missing runtime config, with the fix in the error.** A required env var
  should raise at boot (in `runtime.exs`) with a message showing how to set or generate the
  value — never a silent default in production.
- **Dev/prod splits must be explicit and narrow.** Scope each divergence (HTTPS redirection,
  relaxed cookie policy, seed data) to the narrowest environment that needs it. Seed data
  must be idempotent and structurally unable to run outside dev.
- **Coordinate graceful shutdown end-to-end**: the app's drain timeout, the supervisor's
  stop timeout, and the reverse proxy's retry policy must agree, or "zero-downtime deploy"
  drops requests at exactly one layer.

## 10. Commit hygiene: the history is the second documentation

- **Conventional Commits with scope, and the _why_ in the body.** Non-trivial commits
  narrate the failure scenario, the root cause, the fix, and the verification. Done
  consistently, the history doubles as an incident and postmortem log — and makes a document
  like this one possible to write from the log alone.
- **Separate commits by intent.** Feature work, formatting fixups, and doc syncs are never
  mixed.
- **Re-run format before committing.** A formatting-only fixup commit is pure noise that one
  pre-commit check would have prevented.
