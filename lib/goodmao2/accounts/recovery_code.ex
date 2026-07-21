defmodule Goodmao2.Accounts.RecoveryCode do
  @moduledoc """
  Schema for a one-time two-factor recovery code (ADR-0013).

  Each code is a cryptographically random 8-character base32 string (~41 bits of
  entropy), stored only as an **HMAC-SHA256 hash** keyed with a server-side secret
  derived from `SECRET_KEY_BASE` — the raw code is shown once at generation and never
  persisted. Codes are generated in batches of ten; each is single-use (`used_at` is
  stamped on consumption). Regenerating a set deletes the previous one.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Goodmao2.Accounts.User

  schema "recovery_codes" do
    field :code_hash, :binary
    field :used_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "Casts and validates fields for creating a recovery code record."
  def changeset(recovery_code, attrs) do
    recovery_code
    |> cast(attrs, [:user_id, :code_hash, :used_at])
    |> validate_required([:user_id, :code_hash])
    |> assoc_constraint(:user)
  end
end
