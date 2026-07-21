// Native (Rust) NIFs for GoodMao, loaded by `Goodmao2.Native`.
//
// This is placeholder scaffolding: `add/2` proves the toolchain, the build wiring, and the
// Elixir <-> Rust boundary all work end to end. Replace it with real NIFs later.
//
// Rules of thumb for anything added here:
//   * A NIF must return quickly (< ~1 ms). For longer work, use a dirty scheduler
//     (`#[rustler::nif(schedule = "DirtyCpu")]`) or a dirty-IO variant — never block the
//     BEAM's normal schedulers.
//   * Prefer returning `Result<T, E>` / an error term over panicking; a panic unwinds into
//     a NIF crash.

#[rustler::nif]
fn add(a: i64, b: i64) -> i64 {
    a + b
}

// Auto-registers every `#[rustler::nif]` in this crate against the Elixir module below.
rustler::init!("Elixir.Goodmao2.Native");
