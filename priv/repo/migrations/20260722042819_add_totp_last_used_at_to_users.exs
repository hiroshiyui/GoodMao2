defmodule Goodmao2.Repo.Migrations.AddTotpLastUsedAtToUsers do
  use Ecto.Migration

  # Records the timestamp of the last TOTP code consumed at login, so the same code cannot be
  # replayed within its 30-second window (ADR-0013). Nil until a user first completes a TOTP
  # challenge.
  def change do
    alter table(:users) do
      add :totp_last_used_at, :utc_datetime
    end
  end
end
