defmodule Goodmao2.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false

      # Audit only, no schema navigation — who sent it. Nilified on user deletion so
      # the message survives (rendered as a deleted user).
      add :sender_id, references(:users, on_delete: :nilify_all)

      # Capped at 2,000 characters both here (the column) and in the changeset. The
      # column counts codepoints, so the changeset validates `count: :codepoints` to
      # match exactly.
      add :body, :string, size: 2000, null: false

      # Soft-delete marker (ADR-0008).
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Thread ordering: a conversation's messages oldest-first.
    create index(:messages, [:conversation_id, :inserted_at])
  end
end
