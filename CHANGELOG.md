# Changelog

All notable changes to GoodMao2 are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to adhere
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version of record is
the `version:` in `mix.exs`; a release tags it as `vX.Y.Z` (see the `release-engineering`
skill).

## [Unreleased]

### Added

- **Daily-life logs (`life` type) as text notes** — any caretaker can now author a
  daily-life entry from QuickLog; its required caption is the base `note`. This completes
  the last log type that had no user-facing authoring path (photo/video enrichment remains
  deferred with the media work). The demo seed now exercises every shipped type.

- **CI** — a GitHub Actions `mix` job (Erlang/Elixir pinned from `.tool-versions`) running
  the gate against a Postgres service: compile with warnings-as-errors, format check,
  unused-deps check, dependency audit, Sobelow scan, and the full test suite.
- **Dependabot** — weekly grouped updates for Hex (`mix`) and GitHub Actions.
- **Security tooling in the gate** — `mix_audit` (advisory audit) and `sobelow` (Phoenix
  static scan) added to `mix precommit` and CI.
- **`GET /health`** — an unauthenticated liveness/readiness probe returning `200 ok` when
  the database is reachable, `503` otherwise.
- **Content-Security-Policy** — a per-request, nonce-based CSP on the browser pipeline
  (`Goodmao2Web.Plugs.ContentSecurityPolicy`); the sole inline script carries the nonce and
  the LiveView socket is covered by `connect-src 'self'`.
- **`mix goodmao.doctor`** — an environment preflight task (runtime versions vs
  `.tool-versions`, Postgres reachability + `CREATEDB`, deps, asset installers, prod secrets).
- **Locale-parity test** — guards structural parity of the `en` / `zh_TW` / `ja_JP` Gettext
  catalogs (identical domains and msgids, no fuzzy entries, templates merged).
- **Accessibility & UX polish** — skip-to-content link, a `:focus-visible` brand ring,
  `aria-hidden` on decorative `<.icon>` glyphs (with an opt-out), a global
  `prefers-reduced-motion` guard, Fluent elevation/motion design tokens with `.gm-lift` /
  `.gm-press` utilities, a `theme-color` meta + inline SVG favicon + branded page title, a
  sticky app-shell with a footer, and a reduced-motion-aware pointer-glow hook.
- **`a11y-engineering` Claude skill** — accessibility auditing/fixing workflow for the
  Phoenix/LiveView layer, completing GoodMao's seven-skill set.
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

- **Gentler tone for ended pets** — a pet's ended lifecycle status (on the pet card and
  header) now shows in a muted tone with a soft glyph — a heart for a pet that has passed
  away — instead of alarming warning-amber, honouring ADR-0003's "be gracious to people"
  principle. The end-of-care page's explanation now spells out the full reassurance (the
  record and timeline are kept and stay reachable by direct link; the pet just leaves the
  active list; hiding history is a separate, reversible choice).
- Hard-fenced `priv/repo/seeds.exs` to the `:dev` environment so its demo accounts can
  never be planted in staging/production.

## [0.1.0] - 2026-07-18

Initial GoodMao2 baseline — the Phoenix/LiveView port's MVP core: scope-based
authentication with a public `@handle`, pets with an end-of-care lifecycle, resource-based
per-pet authorization, structured one-table log entries, and a live, filterable timeline
over Phoenix PubSub. Trilingual Gettext scaffolding (`en` / `zh_TW` / `ja_JP`) and the
`mix precommit` gate.
