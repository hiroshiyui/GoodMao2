# 7. Explicit error reporting without exposing sensitive information

- **Status:** Accepted
- **Date:** 2026-07-14
- **Deciders:** GoodMao maintainers

> _Ported from GoodMao ADR-0007, adapted for the GoodMao2 Phoenix/LiveView/Gettext stack._

## Context

GoodMao2 is an internet-facing service handling sensitive pet health data, and it is
meant to meet people honestly and graciously. Those two pulls collide precisely at
error reporting:

- **Too vague / mislabelled.** If a login or register form reports "Invalid
  credentials" / "Could not create the account" and marks the input fields
  `aria-invalid` when the *server* is at fault, it blames the user for an outage. An
  error that lies about its cause is worse than no message: it sends the user to fix the
  wrong thing, and it fails assistive technology, which reads the false "invalid field"
  state aloud.
- **Too candid.** The opposite failure is just as real. Echoing a framework's
  duplicate-account error verbatim confirms whether an email is registered (user
  enumeration); a raw `500` leaks stack traces, SQL, or file paths; a "forbidden" on a
  resource the caller may not see confirms that the resource exists.

We do not want to re-decide this per LiveView and per form. It needs one written rule,
because the two halves are easy to trade off against each other by accident — making an
error clearer often means making it leak, and making it safe often means making it
useless.

## Decision

**We indicate errors explicitly without exposing sensitive information** — treated as a
single rule with two inseparable halves.

- **Explicit about what the user can act on.** Tell the user honestly and specifically
  what failed, and never mislabel one failure as another. A backend/service fault
  surfaces as a distinct, retryable state, separate from a genuine credential/validation
  error. Only the fields actually at fault carry `aria-invalid`; a service fault leaves
  the form unmarked. The distinctions that matter to the user must survive all the way to
  the copy and the ARIA state.

- **Silent about what an attacker could exploit.** User-facing error copy must not reveal
  whether an account exists, must not expose internal state (stack traces, SQL, file
  paths, framework error text), and must not confirm the presence of a protected
  resource. This reaffirms the project's existing conventions: a pet the caller has no
  grant for returns **`{:error, :not_found}`, not "forbidden"** (existence hidden — see
  [ADR-0004](0004-log-visibility.md) and the "Resource-based authorization" rule in
  `AGENTS.md`), and registration does not echo an account-already-exists error. Full
  closure of user-enumeration awaits an email-confirmation flow; until then, keep
  register/login/reset responses uniform where feasible.

- **The line between the halves.** "Sensitive" means: existence of accounts or protected
  resources, internal/technical detail, and anything that narrows an attacker's search.
  Everything else — *what the user typed wrong, what is temporarily down, what to try
  next* — is not sensitive and should be stated plainly. When a message could go either
  way, prefer the wording that helps the legitimate user while staying uniform across the
  enumerable cases.

- **Where each string lives.** All user-facing copy — including error and flash messages
  and `aria-*` text — goes through **Gettext**, localized in every locale, kept in sync
  via `mix gettext.extract && mix gettext.merge priv/gettext`. In this monolith there is
  no cross-tier duplication to guard against, but the same discipline applies: one message
  id per string, translated everywhere.

## Consequences

- A written tie-breaker for every future LiveView and form: be explicit about the
  actionable cause, silent about the exploitable detail. New error paths are reviewed
  against both halves, not one.
- Better accessibility: honest, correctly-scoped error and `aria-invalid` states mean
  assistive tech announces the real problem, not a misattributed one — reinforcing the
  project's accessibility-first rule.
- Some friction is deliberate. Uniform responses across enumerable cases
  (register/login/reset) can feel less helpful to a legitimate user who mistyped; we
  accept that until email confirmation lets us be both safe and specific. Revisit this
  ADR when that flow lands.

## Alternatives considered

- **Leave it to per-case judgement.** Rejected: that is the status quo that produces both
  the mislabelled-outage bug and the user-enumeration leak. The trade-off is too easy to
  get wrong silently without a written rule.
- **Generic "something went wrong" everywhere (fail closed on candour).** Safe against
  leaks but strands users on unactionable errors and reads as indifferent at exactly the
  moments (a sick pet, a grieving owner) when clarity matters most.
- **Maximally specific everywhere (fail open on candour).** Best-feeling UX but reopens
  user enumeration and internal-detail leaks on a security-critical, internet-facing
  service. Rejected.
