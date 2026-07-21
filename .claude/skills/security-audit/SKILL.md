---
name: security-audit
description: Perform a dedicated, project-wide security audit of GoodMao — resource-based per-pet authorization, injection/output encoding, authentication/session management, secrets, configuration/logging, native (Rust NIF) code, and dependency advisories — mapped to the OWASP Top 10, then report findings by severity and fix critical issues.
---

GoodMao handles **sensitive pet health data** shared across multiple caretakers and vets.
The dominant risk is **broken access control**: one user reading or writing another's pet
timeline. Conduct a **full project-wide security sweep**; treat every fetch-by-id and every
write as a potential authorization bypass until proven scoped.

This skill audits security only. For correctness, tests, docs, and a11y, use `code-review`.

---

## Step 1 — Orient and Threat-Model

- Read `CLAUDE.md`, `AGENTS.md` (GoodMao section), and `doc/architecture.md` (the
  authorization table).
- Enumerate trust boundaries, most-exposed first:
  1. **Authenticated user input** — pets, access grants, log entries, profile/handle.
  2. **The authorization core** (`lib/goodmao2/pets.ex`) — every capability decision.
  3. **Public/guest surface** — the landing page, registration, login, magic-link, password reset.
  4. **Admin** — the global `is_admin` role (must NOT reach pet data).
  5. **Native code** — the `native/goodmao2_native` Rust NIF crate runs inside the BEAM
     (see Step 8); terms crossing the FFI boundary are attacker-influenced input.
- Skim `mix.exs` / `mix.lock` and `native/goodmao2_native/Cargo.toml` for the dependency inventory.

---

## Step 2 — Authorization and Access Control (the core — OWASP A01)

- **Every fetch-by-id is scoped or permission-checked.** LiveViews load pets via
  `Pets.fetch_pet(user, id, require: level)` and act on `{:error, :not_found}` — never
  `Repo.get(Pet, id)` followed by unguarded use. Inaccessible resources return
  **not-found, never "forbidden"** (IDOR-hidden); confirm no error path leaks existence.
- **Capability re-checked at the context boundary**, not only at mount. `Logs.create_entry`/
  `update_entry`/`delete_entry` call `Pets.can?/3`; `vet_note` is vet-only; changing a log's
  `visibility` is owner-only. A stale socket assign must not grant a write.
- **Effective-grant definition** (`status == "active"` AND (`expires_at` nil OR future)) is
  applied everywhere access is computed — `effective_access`, `can?`, `list_pets`,
  `list_accesses`. A revoked or expired grant must confer nothing.
- **Owner invariant**: pet creation inserts the `owner` grant transactionally; revoking the
  last effective owner is refused (`:last_owner`). Verify the guard counts only *effective*
  owners and excludes the row being revoked.
- **No admin backdoor**: `is_admin` grants global platform actions only. Grep for any query
  that special-cases admins to bypass `PetAccess` — there must be none.
- **Grant resolution**: `grant_access` resolves grantees by `@handle` or email; only a
  `:manage` holder can grant; an unknown identifier returns `:grantee_not_found` (no user
  enumeration beyond what a handle lookup inherently allows).

---

## Step 3 — Injection and Output Encoding (A03)

- No `String.to_atom/1` on any external input (atom-table exhaustion); prefer fixed
  allowlists (the schemas expose `roles/0`, `types/0`, etc.).
- No user input in file paths (path traversal); no user-supplied filenames on disk.
- All Ecto queries parameterized; no interpolation of user values into `fragment()`.
- HEEx: all dynamic values rendered with `{@var}` (auto-escaped); audit every `raw/1` /
  `{:safe, ...}` — none should wrap untrusted content (XSS). The `data` `jsonb` payload and
  free-text `note` are user-controlled and must render escaped.
- No user input in shell commands, `Code.eval_*`, or `:erlang.binary_to_term/1`.

---

## Step 4 — Authentication and Session Management (A02/A07)

- Auth is `phx.gen.auth` (scope-based). Verify the generated flow is intact: password hashing
  via `bcrypt_elixir`, magic-link/password-reset tokens single-use, expiring, and hashed at
  rest; session tokens rotated appropriately.
- Sensitive account actions (email/password change in `UserLive.Settings`) sit behind
  `:require_sudo_mode`; the sudo window is enforced (`Accounts.sudo_mode?`).
- Router scoping: authenticated pet routes live in the `:require_authenticated_user`
  `live_session` with the `:require_authenticated` `on_mount`; guest-only pages redirect
  authenticated users. No sensitive route is reachable from the wrong pipeline.
- Login/registration/reset responses don't create a user-enumeration oracle beyond the
  generator's design.

---

## Step 5 — Secrets and Crypto (A02)

- `secret_key_base` and the DB URL come from runtime env (`config/runtime.exs`), never
  compiled in; scan the repo for accidentally-committed secrets or credentials.
- Randomness for tokens uses the framework's crypto-strong generators (via `phx.gen.auth`),
  never `:rand` for security material.
- No plaintext secrets, tokens, or password hashes in logs or error output.

---

## Step 6 — Configuration and Logging (A05/A09)

- Security headers via `put_secure_browser_headers`; HTTPS/HSTS enforced in production
  (`config/runtime.exs`/prod); session cookies `secure` + `http_only` + `same_site`.
- Dev-only routes (`/dev/dashboard`, `/dev/mailbox`) are gated behind
  `dev_routes`/`code_env` and unreachable in production.
- Error handling: no stack traces or internal details in user-facing responses in prod.
- Security-relevant events are observable without logging secrets or tokens.

---

## Step 7 — Data Exposure via Visibility & Soft-Delete (A01)

- The per-entry `visibility` (`private`/`limited`/`public`) is honoured on read paths, and
  only owners can change it. (The public share-token surface is deferred per
  `doc/roadmap.md` — confirm no half-wired public read path exposes data early.)
- Soft-deleted entries (`deleted_at`) are excluded from every read — they must not resurface
  via a filter that forgets `is_nil(deleted_at)`.
- `history_hidden` pets: confirm the intended existence-hiding is enforced wherever it's read
  (or noted as deferred if the UI path isn't wired yet).

---

## Step 8 — Native Code (Rust NIFs) (A08)

The `native/goodmao2_native` crate runs **inside the BEAM as native code** — it bypasses the
VM's memory safety and fault isolation, so a bug here is a whole-node concern, not a process
crash. Audit every NIF:

- **No panics across the boundary.** A Rust `panic!` (including `unwrap()`/`expect()`/slice
  out-of-bounds/integer overflow in debug) unwinds into a NIF crash. NIFs must return
  `Result`/error terms, not panic. Grep the crate for `unwrap(`, `expect(`, `panic!`, `[..]`
  indexing on caller-controlled lengths.
- **`unsafe` is justified.** Every `unsafe` block needs a comment proving its invariants;
  treat unexplained `unsafe`, raw pointers, or `transmute` as a finding.
- **Inputs are validated at the boundary.** Terms decoded from Elixir are attacker-influenced
  — bound sizes/lengths before allocating or indexing; never trust a decoded length.
- **No scheduler starvation (DoS).** A NIF that can run longer than ~1 ms must use a dirty
  scheduler (`#[rustler::nif(schedule = "DirtyCpu"/"DirtyIo")]`); an unbounded loop or large
  allocation on a normal scheduler stalls the whole node.
- **Build integrity.** The `rustler` crate version tracks the Elixir `:rustler` dep; the built
  `.so` under `priv/native/` is a git-ignored artifact (never committed); `Cargo.lock` **is**
  committed for reproducible builds.

## Step 9 — Dependency Vulnerabilities (A06)

```bash
mix hex.audit          # retired packages + security advisories (EEF/GHSA/OSV)
mix hex.outdated       # context for what a fix bump would require
cd native/goodmao2_native && cargo audit   # RustSec advisories for the NIF crate's crates
```

- Triage each advisory: **production vs test-only** (use `mix deps.tree`), **fix availability**
  (bump vs replace an unmaintained package), and any **existing mitigation**.
- Frontend: check the pinned esbuild/Tailwind versions and vendored daisyUI against npm
  advisories (see the `check-updates` skill for mechanics).
- Rust: `cargo audit` for the NIF crate; treat a RustSec advisory like a Hex one.
- Report each with: package, **current → fixed** (or "no fix — replace"), severity,
  production-vs-test, advisory ID.

---

## Step 10 — OWASP Top 10 Cross-Check

Explicitly close out each category, citing where it was checked:

| Category | Primary steps |
|----------|---------------|
| A01 Broken Access Control | 2, 7 |
| A02 Cryptographic Failures | 4, 5 |
| A03 Injection | 3 |
| A04 Insecure Design | 2, 7 |
| A05 Security Misconfiguration | 6 |
| A06 Vulnerable & Outdated Components | 9 |
| A07 Identification & Auth Failures | 4 |
| A08 Software & Data Integrity Failures | 5, 8, 9 |
| A09 Logging & Monitoring Failures | 6 |
| A10 SSRF | n/a today — no server-side fetch of user-supplied URLs ships yet; becomes live when link previews / media / Web Push land (see `doc/roadmap.md`) |

---

## Reporting

Present all findings grouped by severity:

| Severity | Criteria |
|----------|----------|
| **Critical** | Auth bypass / IDOR on pet data, injection, secret exposure, owner-invariant break |
| **Major** | Exploitable with preconditions: missing capability re-check, weak validation, information disclosure, missing negative-path enforcement |
| **Minor** | Hardening: missing headers, defense-in-depth gaps, logging improvements |

For each finding: cite the **file and line number**, describe the vulnerability, give a
concrete **attack scenario** (who, from where, with what payload), and a **concrete fix**.
If a category was audited and found clean, say so explicitly — silence is not a clean bill.

---

## Fixing

Apply fixes for all **Critical** and **Major** findings directly, and add a negative-path
regression test in `test/` for each. Then run the gate:

```bash
mix precommit
```

The audit is not complete until it passes. When an authorization gap is found once, **sweep
every context function and LiveView for the same class** before finishing.
