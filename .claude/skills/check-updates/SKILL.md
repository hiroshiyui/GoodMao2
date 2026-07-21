---
name: check-updates
description: Check for available updates and security advisories across the dependency ecosystems GoodMao uses — Elixir/Hex packages, the esbuild/Tailwind/daisyUI frontend toolchain, and the Rust/Cargo NIF crate — then report what is outdated, what is blocked by a version constraint, and what is retired/insecure, grouped by risk. Reports findings; does not upgrade without confirmation.
---

GoodMao spans three dependency ecosystems — Elixir/Hex, the vendored/CLI frontend
tooling, and the Rust/Cargo NIF crate (`native/goodmao2_native`) — so a complete update
check must cover all three; `mix hex.outdated` alone misses the JS/CSS toolchain and the
Rust crates.

This skill **reports**. Do not edit `mix.exs`, `config/config.exs`, or vendored files
under `assets/vendor/`, and do not run any upgrade, without explicit user confirmation
of the specific bumps to apply (a framework major/minor bump can break the build).

---

## Step 1 — Elixir / Hex dependencies

```bash
mix hex.outdated        # every dep: Current vs Latest, and whether the mix.exs constraint allows it
mix hex.audit           # retired / deprecated / insecure packages (ALWAYS run — security-relevant)
```

- Note each dep's **Status** column: `Update possible` (constraint already allows it) vs
  `Update not possible` (the `~>` requirement in `mix.exs` pins it — an upgrade needs a
  constraint edit and is usually a minor/major framework bump).
- For every `Update not possible`, run `mix hex.outdated <dep>` to see the exact `mix.exs`
  requirement and what is blocking it.
- Treat **`mix hex.audit` output as the top priority** — a retired/insecure package is a
  security finding, not a routine bump.
- Flag the **security- and framework-critical** deps for extra care even on a minor bump:
  `phoenix`, `phoenix_live_view`, `ecto_sql`/`postgrex`, `bandit`, `bcrypt_elixir`
  (password hashing), `req` (the HTTP client — use it, never HTTPoison/Tesla/httpc),
  `phoenix_ecto`, `gettext`.

## Step 2 — Frontend toolchain

The JS/CSS tools are not in `mix hex.outdated`. esbuild and Tailwind are version-pinned
in `config/config.exs`; daisyUI and heroicons are vendored under `assets/vendor/`.

```bash
# Pinned installer versions
grep -A2 'config :esbuild' config/config.exs   # version: "..."
grep -A2 'config :tailwind' config/config.exs  # version: "..."

# Vendored daisyUI version — read it from a build's banner
mix tailwind goodmao2 2>&1 | grep -i daisyui   # prints "daisyUI x.y.z"; the same line shows "tailwindcss vX.Y.Z"

# Latest published versions
for pkg in esbuild "@tailwindcss/cli" daisyui; do
  echo "$pkg → $(curl -sS "https://registry.npmjs.org/$pkg/latest" | grep -oE '"version":"[^"]+"' | head -1)"
done
```

- Compare pinned/vendored versions against the npm `latest`.
- daisyUI is vendored (`assets/vendor/daisyui.js` + `daisyui-theme.js`), so updating it
  means re-fetching those files per the URL in the `app.css` comment — note that, don't
  attempt it silently.
- heroicons is fetched by the `mix.exs` git dep (tag `v2.2.0`); a bump is a `mix.exs` edit.
- A Tailwind/daisyUI bump can shift component styles — call out that any bump needs a
  visual check of the light/dark themes.

## Step 3 — Rust / Cargo (the NIF crate)

The `native/goodmao2_native` crate (Rustler NIFs) has its own Cargo dependencies, pinned in
`native/goodmao2_native/Cargo.lock`, and a toolchain channel in `rust-toolchain.toml`.

```bash
cd native/goodmao2_native
cargo update --dry-run          # what a `cargo update` would bump (respects Cargo.toml semver)
cargo outdated                  # if cargo-outdated is installed: Current vs Latest per crate
cargo audit                     # RustSec advisories (install: cargo install cargo-audit) — ALWAYS run
```

- **`rustler` lockstep**: the `rustler` crate version in `Cargo.toml` MUST match the Elixir
  `:rustler` dep in `mix.exs` (they release together). Flag any drift as a **required paired
  bump** — bumping one without the other can break the NIF glue.
- Treat **`cargo audit` output as top priority**, exactly like `mix hex.audit`.
- **Toolchain**: compare the `channel` in `rust-toolchain.toml` against the latest stable Rust
  release; a bump changes the compiler for every build host, so verify the crate still builds
  (`mix compile` recompiles the NIF) and note it needs a rebuild on all platforms.

---

## Reporting

Present a single consolidated list grouped by **risk**, not by ecosystem:

| Priority | Criteria |
|----------|----------|
| **Security** | Anything from `mix hex.audit` or `cargo audit`, or a bump that patches a known advisory, or an outdated dep on the auth / crypto / input-handling boundary |
| **Framework (needs care)** | Major/minor bumps of Phoenix, LiveView, Ecto, Bandit, Req, Tailwind/daisyUI, the `rustler` lockstep pair (Elixir dep + Rust crate together), or any `Update not possible` requiring a `mix.exs` constraint edit — each needs its changelog read and the full test suite run |
| **Routine** | Patch/minor bumps of everything else where the constraint already allows it |

For each entry give: **current → latest**, the ecosystem, whether a constraint edit is
required, and a one-line risk note. State explicitly which ecosystems were clean.

## Applying updates (only after the user picks what to bump)

1. Apply the smallest safe set first (routine patch/minor with `Update possible`); keep
   framework majors separate.
2. For Hex: `mix deps.update <dep>` (or edit the `~>` constraint for blocked ones), then
   `mix deps.get`.
3. For frontend: edit the `config/config.exs` version (esbuild/tailwind) or re-vendor
   daisyUI, then `mix assets.build`.
4. For Rust: `cd native/goodmao2_native && cargo update` (or edit `Cargo.toml`); bump the
   `rustler` crate **and** the `:rustler` mix dep together; `mix compile` to rebuild the NIF.
5. **Run the gate after every batch** and stop on any failure: `mix precommit`.
6. For a Tailwind/daisyUI bump, also visually verify the light/dark themes. Commit by
   ecosystem/topic.
