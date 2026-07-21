defmodule Goodmao2.Repo.Migrations.CreateConversationParticipants do
  use Ecto.Migration

  def change do
    create table(:conversation_participants) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # Per-participant read cursor: messages with `inserted_at > last_read_at` are
      # unread. Null = nothing read yet (every message is unread).
      add :last_read_at, :utc_datetime

      # Soft-delete marker (ADR-0008) — a future archive/leave path stamps this;
      # rejoining un-stamps it.
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:conversation_participants, [:conversation_id, :user_id])
    # "My conversations" + the unread rollup that drives the mailbox badge.
    create index(:conversation_participants, [:user_id])
  end
end
