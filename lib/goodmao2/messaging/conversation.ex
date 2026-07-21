defmodule Goodmao2.Messaging.Conversation do
  @moduledoc """
  A private 1:1 conversation between two users — one row per unordered pair.

  The pair is canonical: participants are stored as ordered columns (`user_lo_id <
  user_hi_id`, DB-enforced by a CHECK) with a unique index, so `(a, b)` and `(b, a)`
  resolve to the same conversation. The context normalizes any pair to `(min, max)` via
  `order_pair/2` before insert. `last_message_at` is denormalized for inbox ordering.
  Soft-deleted via `deleted_at`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversations" do
    belongs_to :user_lo, Goodmao2.Accounts.User
    belongs_to :user_hi, Goodmao2.Accounts.User

    field :last_message_at, :utc_datetime
    field :deleted_at, :utc_datetime

    has_many :participants, Goodmao2.Messaging.Participant
    has_many :messages, Goodmao2.Messaging.Message

    timestamps(type: :utc_datetime)
  end

  @doc "Orders a user pair into the canonical `{lo, hi}` (lo < hi)."
  def order_pair(a_id, b_id) when a_id < b_id, do: {a_id, b_id}
  def order_pair(a_id, b_id), do: {b_id, a_id}

  @doc "Changeset for creating a conversation from an already-ordered pair."
  def create_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:user_lo_id, :user_hi_id])
    |> validate_required([:user_lo_id, :user_hi_id])
    |> check_constraint(:user_lo_id,
      name: :user_pair_ordered,
      message: "must be an ordered, distinct pair"
    )
    |> unique_constraint([:user_lo_id, :user_hi_id])
  end
end
