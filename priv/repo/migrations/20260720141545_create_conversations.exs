defmodule Goodmao2.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      # One conversation per unordered user pair. The two participants are stored as
      # ordered columns (lo < hi) so the pair is canonical: a DB CHECK enforces the
      # ordering and a unique index makes the pair the natural key (mirrors the
      # unique_index on pet_accesses [:pet_id, :user_id]). The context normalizes any
      # (a, b) to (min, max) before insert.
      add :user_lo_id, references(:users, on_delete: :delete_all), null: false
      add :user_hi_id, references(:users, on_delete: :delete_all), null: false

      # Denormalized time of the latest message, for inbox ordering without a join.
      add :last_message_at, :utc_datetime

      # Soft-delete marker (ADR-0008).
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create constraint(:conversations, :user_pair_ordered, check: "user_lo_id < user_hi_id")
    create unique_index(:conversations, [:user_lo_id, :user_hi_id])
    create index(:conversations, [:user_hi_id])
  end
end
