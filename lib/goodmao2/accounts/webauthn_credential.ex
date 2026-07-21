defmodule Goodmao2.Accounts.WebAuthnCredential do
  @moduledoc """
  Schema for a registered WebAuthn (FIDO2) credential — one hardware security key or
  platform authenticator enrolled by a user (ADR-0013). A user may enroll several for
  redundancy.

  ## Fields

    * `credential_id` — raw credential ID bytes from the authenticator; the direct
      lookup key at authentication time (globally unique).
    * `public_key_cbor` — the COSE public key, CBOR-encoded, passed to
      `Wax.authenticate/6` for signature verification.
    * `sign_count` — monotonic counter from the authenticator, checked on every
      authentication to detect cloned keys (must never regress).
    * `aaguid` — authenticator model identifier (informational).
    * `label` — user-assigned name, e.g. "YubiKey 5C".
    * `last_used_at` — timestamp of the most recent successful authentication.

  Credentials are **hard-deleted** when a user removes a key — a revoked security
  credential must never authenticate again (a deliberate exception to the app's
  soft-delete convention).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Goodmao2.Accounts.User

  schema "webauthn_credentials" do
    belongs_to :user, User

    field :credential_id, :binary
    field :public_key_cbor, :binary
    field :sign_count, :integer, default: 0
    field :aaguid, :binary
    field :label, :string, default: ""
    field :last_used_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a new credential."
  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:user_id, :credential_id, :public_key_cbor, :sign_count, :aaguid, :label])
    |> validate_required([:user_id, :credential_id, :public_key_cbor])
    |> validate_length(:label, max: 255)
    |> unique_constraint(:credential_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Changeset for updating `sign_count`/`last_used_at` after authentication, or the label."
  def update_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:sign_count, :last_used_at, :label])
    |> validate_required([:sign_count])
    |> validate_length(:label, max: 255)
  end
end
