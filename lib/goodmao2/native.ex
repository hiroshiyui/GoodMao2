defmodule Goodmao2.Native do
  @moduledoc """
  Rust NIFs for GoodMao (see `native/goodmao2_native`).

  The Rust crate is compiled by Rustler during `mix compile` (toolchain pinned by
  `rust-toolchain.toml`) and loaded on module load; each function below is a stub replaced at
  load time by its native implementation. `add/2` is placeholder scaffolding that proves the
  build + boundary work — replace it as real NIFs are added.
  """
  use Rustler, otp_app: :goodmao2, crate: "goodmao2_native"

  @doc "Adds two integers in Rust. Placeholder NIF proving the native boundary."
  def add(_a, _b), do: :erlang.nif_error(:nif_not_loaded)
end
