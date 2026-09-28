// Native (Rust) NIFs for GoodMao, loaded by `Goodmao2.Native`.
//
// This is placeholder scaffolding: `add/2` proves the toolchain, the build wiring, and the
// Elixir <-> Rust boundary all work end to end. Replace it with real NIFs later.
//
// Rules of thumb for anything added here:
//   * Each `#[rustler::nif]` is a thin wrapper over a plain Rust function that holds the
//     logic. `cargo test` exercises the plain function directly -- a NIF itself only runs
//     inside a loaded BEAM -- and CI runs it along with `cargo clippy -D warnings`.
//   * A NIF must return quickly (< ~1 ms). For longer work, use a dirty scheduler
//     (`#[rustler::nif(schedule = "DirtyCpu")]`) or a dirty-IO variant — never block the
//     BEAM's normal schedulers.
//   * Prefer returning `Result<T, E>` / an error term over panicking; a panic unwinds into
//     a NIF crash.

/// Adds two integers, or `None` when the sum overflows `i64`.
///
/// Checked rather than `a + b`, which panics in debug builds and silently wraps in release.
fn checked_add(a: i64, b: i64) -> Option<i64> {
    a.checked_add(b)
}

// An out-of-range sum becomes a `BadArg` error term (an `ArgumentError` in Elixir) instead of
// a panic across the NIF boundary.
#[rustler::nif]
fn add(a: i64, b: i64) -> rustler::NifResult<i64> {
    checked_add(a, b).ok_or(rustler::Error::BadArg)
}

// Auto-registers every `#[rustler::nif]` in this crate against the Elixir module below.
rustler::init!("Elixir.Goodmao2.Native");

#[cfg(test)]
mod tests {
    use super::checked_add;

    #[test]
    fn adds_in_range() {
        assert_eq!(checked_add(2, 3), Some(5));
        assert_eq!(checked_add(-4, 1), Some(-3));
        assert_eq!(checked_add(i64::MAX, 0), Some(i64::MAX));
        assert_eq!(checked_add(i64::MIN, 0), Some(i64::MIN));
    }

    #[test]
    fn overflow_is_none_not_a_wrap() {
        assert_eq!(checked_add(i64::MAX, 1), None);
        assert_eq!(checked_add(i64::MIN, -1), None);
    }
}
