defmodule Goodmao2.Repo.Migrations.CreateWebauthnCredentials do
  use Ecto.Migration

  def change do
    create table(:webauthn_credentials) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Raw credential ID bytes from the authenticator — the lookup key at auth time.
      add :credential_id, :binary, null: false
      # COSE public key, CBOR-encoded, passed to Wax.authenticate/6 for signature checks.
      add :public_key_cbor, :binary, null: false
      # Monotonic counter from the authenticator — clone detection (must not regress).
      add :sign_count, :bigint, default: 0, null: false
      # Authenticator model identifier (informational).
      add :aaguid, :binary
      # User-assigned label, e.g. "YubiKey 5C".
      add :label, :string, default: "", null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Credential IDs are globally unique — used as the direct lookup key.
    create unique_index(:webauthn_credentials, [:credential_id])
    create index(:webauthn_credentials, [:user_id])
  end
end
