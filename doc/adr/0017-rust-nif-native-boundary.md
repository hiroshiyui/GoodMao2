# 17. A Rust/Rustler native boundary for CPU-bound work

- **Status:** Accepted _(scaffolding shipped; no production NIF yet — recorded retroactively)_
- **Date:** 2026-07-21
- **Deciders:** GoodMao maintainers

> _The build wiring and the Elixir ⇄ Rust boundary exist today as proven scaffolding
> (`Goodmao2.Native.add/2`); no real NIF ships yet. Recorded now because adding a native
> toolchain to a Phoenix app is a cross-cutting, hard-to-reverse build/deploy decision that
> should not be discovered only by finding a `native/` directory._

## Context

GoodMao is a Phoenix/Elixir monolith. The BEAM is excellent at concurrency and I/O but is
not the right tool for **tight CPU-bound inner loops** (byte-level parsing, hashing/format
work, image/signal number-crunching). The product already has, and will accumulate more,
such work — e.g. media purification ([ADR-0005](0005-media-storage.md)) shells out to
`ffmpeg` today, but finer-grained native routines may become worthwhile.

Rather than reach for a native library reactively — under pressure, on an unproven
toolchain, in the middle of a feature — the maintainers want the **Elixir ⇄ native boundary
established and proven up front**, so that when a real hot path appears, only the NIF itself
is new, not the entire build/deploy story.

The candidate mechanisms and their costs:

- **Rustler NIFs** — Rust called in-process via a `cdylib`. Fast and safe (Rust's memory
  safety avoids the classic C-NIF footguns), but a NIF that runs too long or panics can
  disrupt the BEAM scheduler.
- **A C NIF** — same performance profile without Rust's safety net.
- **A port / external OS process** — isolates crashes but adds IPC latency and an ops
  surface.
- **Doing nothing** and staying pure Elixir until forced.

## Decision

**Add a Rust NIF crate (`native/goodmao2_native`) loaded via Rustler as
`Goodmao2.Native`, wired into `mix compile`, with a pinned toolchain — as proven
scaffolding for future CPU-bound work. Ship it now with only a placeholder `add/2`.**

- **Rustler + a pinned toolchain.** The `{:rustler, "~> 0.38"}` dep builds the crate during
  `mix compile`; `rust-toolchain.toml` pins the Rust channel (currently `1.95.0`) so
  `rustup` auto-installs the exact version on a build host. The `rustler` **crate** version
  in `Cargo.toml` is kept in lockstep with the `:rustler` **Hex** dep.

- **Proven, minimal surface.** `Goodmao2.Native.add/2` is deliberate placeholder
  scaffolding: it proves the toolchain, the build wiring, and the boundary work end to end,
  and is meant to be replaced as real NIFs are added — the boundary exists before it is
  needed.

- **Discipline for anything added.** A NIF must return quickly (≈ < 1 ms) or use a **dirty
  scheduler** (`schedule = "DirtyCpu"` / dirty-IO) for longer work — never block the BEAM's
  normal schedulers. NIFs prefer returning `Result`/error terms over panicking (a panic
  unwinds into a NIF crash). Build profile release-optimizes even in dev so native work
  isn't debug-slow.

- **Committed vs. generated.** `Cargo.lock` is committed for reproducible builds; the built
  `priv/native/*.so` and `native/*/target/` are git-ignored.

## Consequences

- **When a hot path appears, only the NIF is new.** The build, the module boundary, the
  toolchain pin, and the deploy implications are already solved and exercised.
- **Build hosts need a Rust toolchain.** `mix compile` now requires Rust; `rustup`
  auto-installs the pinned channel, but CI images, Dockerfiles, and future Ansible
  provisioning must have `rustup` available. This is the main hard-to-reverse cost of the
  decision and the reason it is recorded.
- **A version to keep in lockstep.** The `:rustler` Hex dep and the `rustler` crate version
  must move together; the `check-updates` skill tracks this.
- **Carrying scaffolding has a small ongoing cost** — a compile step and a dependency for
  code that does nothing in production yet. Accepted deliberately: proving the boundary
  cheaply now is worth more than the idle weight.
- **Native code forfeits BEAM safety if misused.** The return-fast / dirty-scheduler /
  no-panic rules are load-bearing; a long-running or panicking NIF can destabilize the whole
  node, unlike a crashing Elixir process. The `security-audit` / `code-review` skills should
  treat any real NIF as a boundary to scrutinize.

## Alternatives considered

- **A C NIF** — rejected: same in-process performance as Rust without Rust's memory-safety
  guarantees; the classic source of BEAM-crashing native bugs.
- **A port / external OS process** — rejected as the default: crash isolation is nice, but
  IPC latency and an extra supervised process are overkill for tight numeric routines.
  (Coarse-grained work like media transcoding still shells out to `ffmpeg` — [ADR-0005](0005-media-storage.md)
  — which is precisely this trade-off chosen the other way for a heavyweight, sandboxable
  tool.)
- **Stay pure Elixir until forced** — rejected: it leaves the entire native build/deploy
  story to be figured out under pressure, on an unproven toolchain, exactly when a hot path
  is already hurting. Proving the boundary early is cheap insurance.
- **A precompiled-NIF distribution (e.g. `rustler_precompiled`)** — deferred: worth
  revisiting once a real NIF ships and build-time on deploy hosts becomes a concern; not
  needed for scaffolding.
