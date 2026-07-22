# 13. Second-factor authentication (TOTP + WebAuthn/FIDO2)

- **Status:** Accepted _(shipped)_
- **Date:** 2026-07-21
- **Deciders:** GoodMao maintainers

> _Shipped: TOTP authenticator-app codes with single-use recovery codes, WebAuthn/FIDO2
> hardware security keys as a second factor, a pending-2FA login stage that gates every
> primary-auth path, forced enrollment for the admin, and sudo-gated self-service
> management on `/users/settings/two-factor`._

## Context

GoodMao holds **sensitive pet health data** shared across owners, co-caretakers, and vets,
but an account is protected by a **single factor**: a magic link (the primary path) or an
optional password. A phished password or a hijacked email inbox is enough to take over an
account and read or alter another party's timeline. The maintainers want a **second
factor** for account security, modelled on the sibling project `baudrate`:

- **TOTP** (RFC 6238 authenticator-app codes) with **recovery codes** as the lost-device
  fallback.
- **WebAuthn / FIDO2** hardware security keys.

Two forces shape the design:

1. **Login is magic-link-primary.** Both the magic-link and password paths converge in
   `UserSessionController.create/2 → UserAuth.log_in_user`, and today a valid `"session"`
   token means *fully logged in* — there is no half-authenticated state. A second factor
   that only gated the password path would leave magic-link as a bypass.
2. **The admin is the highest-value account.** The first registered user is the sole global
   administrator; compromising it is the worst case, so its protection should not be
   optional.

WebAuthn attestation and COSE key parsing are genuinely hard to implement safely, unlike
the app's hand-rolled Web Push crypto (ADR-0011) — so vetted libraries are warranted here.

## Decision

**Add TOTP and WebAuthn as opt-in second factors for everyone and a required factor for the
admin, gating every primary-auth path through a new pending-2FA stage. Use `wax_`,
`nimble_totp`, `cbor`, and `eqrcode`.**

- **Pending-2FA stage.** After primary auth verifies, `UserAuth.log_in_or_challenge/3`
  branches on `Accounts.login_next_step/1`: `:authenticated` logs in as before; `:challenge`
  (the user has a factor) and `:setup_required` (an admin with none) both stash a **signed,
  short-lived (10 min) pending marker** in the session and redirect to the challenge/setup —
  **issuing no session token yet**. The `"session"` token is minted only by
  `complete_2fa_login/2` after the factor succeeds. So *"2FA passed" ≡ "a server session
  token exists"* — there is no separate boolean, and the same invariant holds for both the
  magic-link and password paths (no bypass).

- **Admin-required, everyone-else-opt-in.** `login_next_step/1` returns `:setup_required`
  only for `is_admin` users with no factor; regular users with no factor get
  `:authenticated`. The forced setup enrolls TOTP (QR + confirm), shows recovery codes once,
  then completes login. `Accounts.can_remove_second_factor?/2` refuses to let an admin remove
  their **last** factor (a last-owner-style invariant).

- **WebAuthn is second-factor only.** No passwordless/passkey first-factor login. Sudo-mode
  re-auth inherits 2FA for free (re-login runs the challenge); a dedicated in-place sudo-2FA
  prompt is deferred.

- **Secrets encrypted / hashed at rest.** The TOTP secret is AES-256-GCM-encrypted in
  `users.totp_secret` via `Accounts.TotpVault` (key derived from `SECRET_KEY_BASE`, exactly
  like `WebPush.VapidVault`). Recovery codes are stored only as **HMAC-SHA256** hashes and
  are single-use (an atomic `Repo.update_all` stamps `used_at`, TOCTOU-safe). WebAuthn stores
  the credential id, COSE public key (CBOR), and a **sign count** checked for regression
  (clone detection) on every assertion.

- **Credentials are hard-deleted.** Removing a security key `Repo.delete`s the row — a
  deliberate exception to the app-wide soft-delete convention (ADR-0008): a revoked
  credential must **never** authenticate again.

- **Challenges are server-side and single-use.** `Accounts.WebAuthnChallenges` (a supervised
  ETS GenServer) holds each `Wax.Challenge` for 60 s under a random token, popped atomically
  and bound to the user id — the challenge never travels in the cookie.

- **Brute force is throttled.** The completion controller re-verifies every factor
  authoritatively (a LiveView can't set the cookie, and a crafted POST can't skip the check),
  counts attempts in the pending session, and **drops the session after 5 failures**. TOTP
  replay within a 30 s window is rejected by persisting the last-consumed window in
  `users.totp_last_used_at` and passing it as `NimbleTOTP`'s `since:` on the next verify (the
  stamp is cleared when TOTP is disabled). The **primary** password step is throttled
  separately by `Accounts.LoginRateLimiter` (per-address, failed attempts only, reset on success).

## Consequences

- The admin **must** enroll a factor on next login — a one-time friction that materially
  raises the floor on the worst-case account.
- Rotating `SECRET_KEY_BASE` renders stored TOTP secrets and recovery codes undecryptable;
  affected users must re-enroll (the same trade-off already documented for VAPID keys).
- Four new Hex dependencies (`wax_`, `nimble_totp`, `cbor`, `eqrcode`; `wax_` pulls `x509`
  and `asn1_compiler`), tracked by `check-updates` — `wax_`'s app key is literally `:wax_`.
- WebAuthn requires a **secure context**: dev testing runs over `https://localhost:4001`.
- Registration options request `residentKey: "preferred"`, so passkey managers and platform
  authenticators are offered a discoverable credential without breaking plain non-resident
  FIDO2 keys. (Browser-extension passkey providers such as Bitwarden inject an inline script to
  override `navigator.credentials`; whether that injection is offered is a browser/extension
  matter — notably it does not surface under Firefox — and is independent of GoodMao's flow.)
- The full-ceremony happy path (a real authenticator) is exercised manually; automated tests
  cover the state machine, crypto, CRUD, challenge store, no-bypass, lockout, and error paths.
- Deferred: passwordless passkey login, a dedicated in-place sudo-2FA re-prompt, and
  per-user "require 2FA" policy for non-admins.

## Alternatives considered

- **Password-only second factor (skip magic link).** Rejected — magic-link is GoodMao's
  primary login; not gating it would make 2FA trivially bypassable.
- **A separate `two_factor_passed` boolean / token context.** Rejected — issuing the session
  token only after the factor is simpler and leaves no "authenticated but not 2FA'd" state to
  get wrong. Mirrors baudrate.
- **Hand-rolling TOTP and WebAuthn on `:crypto`** (as with Web Push). TOTP alone would be
  feasible, but WebAuthn attestation/COSE/CBOR parsing is not worth the security risk;
  `wax_`/`nimble_totp` are small and well-tested.
- **Storing the WebAuthn challenge in the cookie.** Rejected — a server-side single-use ETS
  store gives atomic consumption and user binding without trusting a client round-trip.
