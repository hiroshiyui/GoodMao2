---
name: docs-engineering
description: Audit and update all GoodMao2 project documentation to stay in sync with the current development status.
---

When performing documentation engineering, always follow these steps:

1. **Audit** all documentation against the current codebase and development status. The
   review scope must include — without exception:
   - `README.md` — feature list ("What's built"), prerequisites, setup, demo accounts
   - `CLAUDE.md` — commands, architecture-in-one-screen, non-obvious conventions
   - `AGENTS.md` — the **GoodMao2 section** (invariants to preserve); keep it in step with
     the code (authorization boundary, one-table logs, soft-delete, a11y, Gettext rules)
   - `doc/architecture.md` — contexts, data model, authorization table, GoodMao→GoodMao2
     technology mapping
   - `doc/roadmap.md` — shipped vs. deferred; move items from "Deferred" to "Shipped" as
     they land
   - `@moduledoc` and `@doc` strings in changed or related modules (the `Pets` authorization
     functions especially — their contracts are the security spec)

2. **Revise and update** any documentation that is stale, incomplete, or inconsistent with
   the current code. Ensure new features, removed dependencies, behavioural changes, schema
   changes, and architectural decisions are reflected accurately. When the data model
   changes, update the schema/authorization descriptions in `doc/architecture.md` in the
   same pass.

3. **Keep the roadmap honest** — when a deferred feature ships, move it to "Shipped" in
   `doc/roadmap.md`; when scope is cut, record it. Do not leave completed work listed as
   pending.

4. **Commit** documentation changes in Git, grouped by topic. Do not mix unrelated
   documentation changes in a single commit.
