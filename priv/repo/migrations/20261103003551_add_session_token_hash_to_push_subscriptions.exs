defmodule Goodmao2.Repo.Migrations.AddSessionTokenHashToPushSubscriptions do
  use Ecto.Migration

  # A push endpoint belongs to a device, and the device is signed in through one session. Keep
  # which session registered it (the SHA-256 of its token, never the token), so revoking that
  # session — log-out, a password change elsewhere, a magic-link login that ends the others —
  # also stops the pushes, instead of a lost phone showing them on its lock screen. Null for
  # rows registered before this column existed: those are released only by the user.
  def change do
    alter table(:push_subscriptions) do
      add :session_token_hash, :binary
    end

    create index(:push_subscriptions, [:session_token_hash])
  end
end
