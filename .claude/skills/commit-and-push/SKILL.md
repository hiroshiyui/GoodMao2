---
name: commit-and-push
description: Stage, commit, and push changes to the remote repository with a well-formed commit message.
---

**Default: land directly on `main`.** Unless the user asks to keep the work on a feature
branch, commit to `main` and push it (fast-forwarding `main` if the work is on a branch). The
`directly` argument is the default behavior, not an opt-in; only stay on a feature branch when
explicitly told to.

When committing and pushing changes, always follow these steps:

1. **Stage** all relevant changes with `git add`. Be deliberate — stage only files related
   to the current topic. Never blindly stage everything with `git add -A` if unrelated
   changes are present.

2. **Commit** with a clear, concise message following the
   [Conventional Commits](https://www.conventionalcommits.org/) standard (e.g.,
   `feat(pets): add coat-colour field`, `fix(logs): filter soft-deleted entries from the
   timeline`). The message should explain *why* the change was made, not just *what*
   changed. Scopes typically map to a context or area: `accounts`, `pets`, `logs`, `web`,
   `docs`, `i18n`, `native` (the Rust NIF crate).

3. **Run the gate before pushing** — `mix precommit` must pass. Do not push a red tree.

4. **Push** to `origin` (the `main` branch by default; the feature branch only when the user
   asked to stay on one). If `git remote` is ever empty, stop after committing and tell the
   user to add a remote first.

5. **Verify** that the push succeeded and the remote is in sync with the local branch.
