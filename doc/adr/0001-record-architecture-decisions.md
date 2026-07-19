# 1. Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-07-09
- **Deciders:** GoodMao maintainers

## Context

GoodMao rests on several consequential, cross-cutting decisions — resource-based per-pet
authorization, one-table structured logs, soft-delete, culture-first localization, a
LiveView monolith, Ecto, Gettext, Oban-when-needed. These decisions and
their rationale otherwise live only in commit messages, `CLAUDE.md`/`AGENTS.md`, and
people's memory, which makes them hard to find and easy to re-litigate.

## Decision

We will record architecture decisions in this directory as **Architecture
Decision Records**, following Michael Nygard's lightweight format (Context /
Decision / Consequences). Each significant decision gets one numbered Markdown
file; superseded decisions are kept for history and linked, never deleted. The
process and conventions are described in [`README.md`](README.md).

## Consequences

- New contributors (and future us) can see *why* the codebase is the way it is,
  not just *what* it is.
- Writing an ADR adds a small step when making a significant decision; this is
  intentional friction that forces the trade-offs to be made explicit.
- `CLAUDE.md`/`AGENTS.md` remain the summary of the *current* decided stack and rules;
  ADRs hold the decision history and reasoning behind it.
- Existing decisions can be back-filled as ADRs over time; absence of an ADR does
  not mean a decision was not made.

## Alternatives considered

- **Keep rationale in commit messages / CLAUDE.md only** — not discoverable as a
  set, and CLAUDE.md documents the current state rather than the reasoning and
  the roads not taken.
- **A single running decisions log** — harder to give each decision a stable
  status, reference, and supersession chain than one-file-per-decision.
