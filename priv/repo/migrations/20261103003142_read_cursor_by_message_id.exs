defmodule Goodmao2.Repo.Migrations.ReadCursorByMessageId do
  use Ecto.Migration

  # The read cursor was a second-resolution timestamp, and a message counted as unread only
  # when `inserted_at > last_read_at`. A reply landing in the same second as the reader's
  # cursor update compared equal and was never counted. Message ids are strictly increasing,
  # so the cursor becomes "the newest message id this participant has read".
  def up do
    alter table(:conversation_participants) do
      # A plain id, not a foreign key: messages are soft-deleted, and the cursor only orders.
      add :last_read_message_id, :bigint
    end

    flush()

    # Carry each cursor over as the newest message it already covered (the old `<=` rule).
    execute("""
    UPDATE conversation_participants AS p
    SET last_read_message_id = (
      SELECT max(m.id) FROM messages AS m
      WHERE m.conversation_id = p.conversation_id AND m.inserted_at <= p.last_read_at
    )
    WHERE p.last_read_at IS NOT NULL
    """)

    alter table(:conversation_participants) do
      remove :last_read_at
    end
  end

  def down do
    alter table(:conversation_participants) do
      add :last_read_at, :utc_datetime
    end

    flush()

    execute("""
    UPDATE conversation_participants AS p
    SET last_read_at = m.inserted_at
    FROM messages AS m
    WHERE m.id = p.last_read_message_id
    """)

    alter table(:conversation_participants) do
      remove :last_read_message_id
    end
  end
end
