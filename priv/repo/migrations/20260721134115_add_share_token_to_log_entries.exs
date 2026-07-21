defmodule Goodmao2.Repo.Migrations.AddShareTokenToLogEntries do
  use Ecto.Migration

  def change do
    # Per-entry anonymous share links (ADR-0004). A `public` entry carries an unguessable,
    # non-enumerable URL-safe token; narrowing visibility clears it. `share_expires_at` is an
    # optional link expiry. The unique **partial** index enforces token uniqueness only over the
    # minted rows, and is the sole index the anonymous read path queries.
    alter table(:log_entries) do
      add :share_token, :string
      add :share_expires_at, :utc_datetime
    end

    create unique_index(:log_entries, [:share_token], where: "share_token IS NOT NULL")
  end
end
