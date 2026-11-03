defmodule Goodmao2.Messaging.Participant do
  @moduledoc """
  A user's membership in a conversation, carrying their per-participant **read cursor**
  (`last_read_message_id`): a message is unread for this participant when its id is greater
  (null = nothing read yet). An id, not a timestamp: a second-resolution `last_read_at` let a
  reply landing in the same second as the cursor update compare equal and never count.
  Soft-deleted via `deleted_at` for a future archive/leave path; rejoining clears it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversation_participants" do
    belongs_to :conversation, Goodmao2.Messaging.Conversation
    belongs_to :user, Goodmao2.Accounts.User

    field :last_read_message_id, :integer
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a participant row."
  def create_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:conversation_id, :user_id, :last_read_message_id])
    |> validate_required([:conversation_id, :user_id])
    |> unique_constraint([:conversation_id, :user_id])
  end
end
