# Changelog

All notable changes to GoodMao2 are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to adhere
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version of record is
the `version:` in `mix.exs`; a release tags it as `vX.Y.Z` (see the `release-engineering`
skill).

## [Unreleased]

### Added

- **CI** — a GitHub Actions `mix` job (Erlang/Elixir pinned from `.tool-versions`) running
  the gate against a Postgres service: compile with warnings-as-errors, format check,
  unused-deps check, dependency audit, Sobelow scan, and the full test suite.
- **Dependabot** — weekly grouped updates for Hex (`mix`) and GitHub Actions.
- **Security tooling in the gate** — `mix_audit` (advisory audit) and `sobelow` (Phoenix
  static scan) added to `mix precommit` and CI. A Content-Security-Policy is intentionally
  deferred (tracked in the roadmap) and ignored via `.sobelow-conf`.
- **`GET /health`** — an unauthenticated liveness/readiness probe returning `200 ok` when
  the database is reachable, `503` otherwise.
- **Project documentation** — glossary, ADRs, a common-practices reference, and expanded
  roadmap sections, ported from and adapted to the Phoenix stack.
- **Brand theme** — GoodMao's "Terracotta + Teal" identity as daisyUI light/dark themes
  (WCAG-verified contrast).

### Security

- Enforced authorization/visibility rules that were modeled but not enforced (GoodMao
  parity audit): `history_hidden` on every log read/write; per-entry `private` visibility
  on reads and the live timeline; recorder-or-owner scoping on log edit/delete; the
  ≥1-owner invariant on the grant-update path plus a `FOR UPDATE` row lock; an optional
  site-owner gate on the bootstrap administrator; and stricter `@handle` rules.

### Changed

- Hard-fenced `priv/repo/seeds.exs` to the `:dev` environment so its demo accounts can
  never be planted in staging/production.

## [0.1.0] - 2026-07-18

Initial GoodMao2 baseline — the Phoenix/LiveView port's MVP core: scope-based
authentication with a public `@handle`, pets with an end-of-care lifecycle, resource-based
per-pet authorization, structured one-table log entries, and a live, filterable timeline
over Phoenix PubSub. Trilingual Gettext scaffolding (`en` / `zh_TW` / `ja_JP`) and the
`mix precommit` gate.
