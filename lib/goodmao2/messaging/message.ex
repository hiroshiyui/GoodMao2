defmodule Goodmao2.Messaging.Message do
  @moduledoc """
  A single message in a conversation.

  `sender_id` is an audit-only reference (no schema navigation); a deleted sender is
  nilified and the message survives, rendered as a deleted user. The body is capped at
  2,000 characters — enforced here (`count: :codepoints`, to match the `varchar(2000)`
  column, which counts codepoints) and by the column itself. Soft-deleted via `deleted_at`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @max_body 2000

  def max_body, do: @max_body

  schema "messages" do
    field :conversation_id, :id
    field :sender_id, :id
    field :body, :string
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a message."
  def create_changeset(message, attrs) do
    message
    |> cast(attrs, [:conversation_id, :sender_id, :body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:conversation_id, :sender_id, :body])
    |> validate_length(:body, max: @max_body, count: :codepoints)
  end
end
