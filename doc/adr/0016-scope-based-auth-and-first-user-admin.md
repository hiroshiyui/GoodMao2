# 16. Scope-based authentication and a single first-user administrator

- **Status:** Accepted _(shipped; foundational — recorded retroactively)_
- **Date:** 2026-07-21
- **Deciders:** GoodMao maintainers

> _The authentication and global-role model, in place since the MVP core (extended later by
> [ADR-0013](0013-second-factor-authentication.md)). Recorded now so the "who is the caller"
> and "who is the admin" decisions are written down._

## Context

Every context call needs to know **who is asking** and to pass that identity through the
web layer, workers, and tests uniformly. Phoenix's `phx.gen.auth` ships a **scope** for
exactly this. The open questions were how GoodMao carries the caller, and how it decides
the one **global administrator** — a role needed for the vet-credential review queue
([ADR-0012](0012-vet-access-model.md)), announcements ([ADR-0011](0011-notifications-and-messaging.md)),
and site oversight.

Two forces constrained the admin decision:

1. **There must be exactly one clear administrator**, established without a bootstrap
   console step or a seed-only flag — self-service on first run.
2. **A public deploy is a race.** If "first account = admin" is unguarded, on an open
   instance whoever registers first — possibly an attacker — becomes administrator.

And one hard boundary: the administrator is an **operational** role. It must grant **no**
access to anyone's pet data ([ADR-0014](0014-resource-based-authorization.md)).

## Decision

**Use `phx.gen.auth` scope-based authentication: the caller is
`socket.assigns.current_scope.user`. The first registered user becomes the sole global
administrator (`is_admin`), optionally fenced to a configured site-owner email; admin is a
global operational role that confers no pet access.**

- **Scope carries the caller.** `Goodmao2.Accounts.Scope` wraps the authenticated `user`
  (`Scope.for_user/1`); LiveViews and controllers read `current_scope.user`, and contexts
  take that `%User{}` as the identity to authorize against. Primary auth is
  **magic-link-first** with an optional password; a second factor
  ([ADR-0013](0013-second-factor-authentication.md)) gates every primary path.

- **First user is the administrator.** `Accounts.register_user/1` sets `is_admin: true` on
  the account **iff** no user exists yet (`not Repo.exists?(User)`). There is exactly one
  administrator and it is established on first registration — no console step, no seed flag.

- **Optional site-owner fence.** Because "first to register wins" is attacker-winnable on an
  open deploy, an optional `config :goodmao2, :site_owner_email` (env
  `GOODMAO_SITE_OWNER_EMAIL`) restricts *who* may create that first account: when set, only
  that address may register the first (admin) account, checked **before any insert**
  (`{:error, :not_site_owner}` otherwise). Unset ⇒ registration is open and the first
  account wins — fine for a private/single-tenant instance.

- **Admin is orthogonal to pet data.** `is_admin` authorizes global operational surfaces
  only — the read-only `/admin` overview, the vet-review queue, announcement composition,
  Web Push VAPID settings. It is **never** consulted by the pet authorization path; there is
  no admin backdoor to a pet's timeline ([ADR-0014](0014-resource-based-authorization.md)).

## Consequences

- **One identity mechanism everywhere.** Contexts, workers, and tests all authorize against
  a `%User{}` resolved from the scope; there is no parallel "current user" plumbing to keep
  in sync.
- **Zero-ceremony admin bootstrap**, at the cost of a first-run race that the site-owner
  fence closes when the deploy needs it. Operators of public instances are expected to set
  `GOODMAO_SITE_OWNER_EMAIL`; `mix goodmao.doctor` surfaces required prod secrets.
- **The admin/pet-access separation is load-bearing.** Any future admin feature must resist
  the temptation to "just let the admin see it" for pet data; oversight surfaces show
  counts and identities, not timelines.
- **Exactly one administrator.** There is no admin-management UI: the role is conferred only
  at first registration. Transferring or adding administrators is a deliberate future
  decision, not an accident of the current model.
- Follow-on auth hardening (handle rules, the registration gate, 2FA) all attach to this
  model rather than replacing it.

## Alternatives considered

- **Hand-rolled auth** — rejected: `phx.gen.auth` is the vetted, maintained Phoenix
  convention; reinventing session/token handling is pure risk.
- **A separate `admins` table or a seed-assigned admin** — rejected: heavier than a single
  `is_admin` boolean and needs an out-of-band bootstrap step; first-user self-service is
  simpler and the site-owner fence covers the abuse case.
- **Admin implies read access to all pets** — rejected outright: it would break the
  product's core privacy promise. Admin is operational only.
- **Always require the site-owner email** — rejected: needless friction for a private,
  single-tenant install where the first (and only) registrant is obviously the owner; the
  fence is opt-in for public deploys.
