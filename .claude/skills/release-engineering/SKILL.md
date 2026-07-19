---
name: release-engineering
description: Manage the full GoodMao release process, including version bumps, changelogs, Git tags, and GitHub releases.
---

When performing release engineering, always follow these steps:

1. **Determine the release type** — review all unreleased commits since the last tag and
   classify the release as `major`, `minor`, or `patch` following
   [Semantic Versioning](https://semver.org/). Present the recommendation to the user and
   confirm before proceeding.

2. **Run the gate** — run the full pre-commit gate and wait for it to pass before
   proceeding. **Do not continue if anything fails.**
   ```bash
   mix precommit
   ```

3. **Update the version** — bump the `version` field in `mix.exs` to match the new release
   version.

4. **Update `CHANGELOG.md`** — add a new version entry at the top following the
   [Keep a Changelog](https://keepachangelog.com/) format. Group changes under `Added`,
   `Changed`, `Fixed`, `Removed`, or `Security` as appropriate. Include all notable changes
   since the previous release. If `CHANGELOG.md` does not exist yet, create it with an
   `## [Unreleased]` section and this release as the first versioned entry.

5. **Commit the release** — stage `mix.exs` and `CHANGELOG.md` together and commit with the
   message `chore: release vX.Y.Z`.

6. **Tag the release** — create an annotated Git tag (e.g., `git tag -a v1.2.3 -m "v1.2.3"`)
   and push it to the remote (`git push --tags`).

7. **Create a GitHub release** — if a GitHub remote is configured, use
   `gh release create vX.Y.Z` with the corresponding `CHANGELOG.md` section as the release
   body. (There is no remote configured yet — if so, stop after tagging and tell the user a
   remote is required for this step.)
