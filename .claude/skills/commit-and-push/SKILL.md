---
name: commit-and-push
description: Stage, commit, and push changes to the remote repository with a well-formed commit message.
---

When committing and pushing changes, always follow these steps:

1. **Stage** all relevant changes with `git add`. Be deliberate — stage only files related
   to the current topic. Never blindly stage everything with `git add -A` if unrelated
   changes are present.

2. **Commit** with a clear, concise message following the
   [Conventional Commits](https://www.conventionalcommits.org/) standard (e.g.,
   `feat(pets): add coat-colour field`, `fix(logs): filter soft-deleted entries from the
   timeline`). The message should explain *why* the change was made, not just *what*
   changed. Scopes typically map to a context or area: `accounts`, `pets`, `logs`, `web`,
   `docs`, `i18n`.

3. **Run the gate before pushing** — `mix precommit` must pass. Do not push a red tree.

4. **Push** the committed changes to the current branch on the remote repository. (No
   remote is configured yet — if `git remote` is empty, stop after committing and tell the
   user to add a remote first.)

5. **Verify** that the push succeeded and the remote is in sync with the local branch.
