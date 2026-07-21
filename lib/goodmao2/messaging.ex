defmodule Goodmao2.Messaging do
  @moduledoc """
  The Messaging context: private 1:1 conversations between users.

  **Shared-pet gate (the abuse boundary).** You may start a conversation only with someone
  you already share a pet with — an effective grant (`status == "active"` and not expired)
  on a common pet. Resolving the recipient and the gate collapse into a single uniform
  `{:error, :cannot_message}` — whether the recipient doesn't exist, is yourself, or merely
  shares no pet — so messaging never reveals which (ADR-0007).

  One conversation exists per unordered pair (canonical `(user_lo_id, user_hi_id)`, DB
  unique + CHECK ordered). Reading or sending within a thread requires being a
  participant; a non-participant sees `nil`/`{:error, :not_participant}` (existence
  hidden). Each participant carries a read cursor (`last_read_at`); a message is unread
  when it arrived after that cursor and wasn't sent by the reader.

  Unread counts and new messages are live over PubSub: a per-user topic carries the
  recomputed mailbox count (badge), and a per-conversation topic carries new messages.
  Messages are capped at 2,000 characters and soft-deleted (`deleted_at`).
  """
  import Ecto.Query, warn: false

  alias Goodmao2.{Accounts, Repo}
  alias Goodmao2.Accounts.User
  alias Goodmao2.Messaging.{Conversation, Message, MessagePushWorker, Participant}
  alias Goodmao2.Notifications
  alias Goodmao2.Notifications.WebPush

  ## PubSub

  @user_prefix "user_messages:"
  @conversation_prefix "conversation:"

  @doc "The PubSub topic carrying a user's mailbox-count updates."
  def topic(%User{id: id}), do: topic(id)
  def topic(user_id), do: @user_prefix <> to_string(user_id)

  @doc "Subscribes the caller to a user's mailbox-count updates."
  def subscribe(user_or_id), do: Phoenix.PubSub.subscribe(Goodmao2.PubSub, topic(user_or_id))

  @doc "The PubSub topic carrying a conversation's new messages."
  def conversation_topic(%Conversation{id: id}), do: conversation_topic(id)
  def conversation_topic(id), do: @conversation_prefix <> to_string(id)

  @doc "Subscribes the caller to a conversation's new messages."
  def subscribe_conversation(conversation_or_id),
    do: Phoenix.PubSub.subscribe(Goodmao2.PubSub, conversation_topic(conversation_or_id))

  ## The shared-pet gate

  @doc """
  Returns `true` if `a` and `b` share at least one pet through effective grants.

  A self-join on `pet_accesses`, both grants effective (`status == "active"` and not
  expired) — the same predicate as `Pets.effective_access/2`. No lifecycle filter.
  """
  def can_message?(%User{id: a}, %User{id: b}) when a != b do
    now = now()

    Repo.exists?(
      from a1 in Goodmao2.Pets.PetAccess,
        join: a2 in Goodmao2.Pets.PetAccess,
        on: a2.pet_id == a1.pet_id,
        where: a1.user_id == ^a and a2.user_id == ^b,
        where: a1.status == "active" and (is_nil(a1.expires_at) or a1.expires_at > ^now),
        where: a2.status == "active" and (is_nil(a2.expires_at) or a2.expires_at > ^now)
    )
  end

  def can_message?(%User{}, %User{}), do: false

  ## Conversations

  @doc """
  Starts (or returns the existing) conversation between `from` and the resolved recipient.

  The recipient is resolved by `@handle` or email. Returns `{:error, :cannot_message}`
  uniformly if the recipient is unknown, is the caller, or shares no pet. Idempotent: the
  canonical pair maps to one conversation, and a participant who had left is revived.
  """
  def start_conversation(%User{} = from, identifier) when is_binary(identifier) do
    with %User{} = to <- Accounts.resolve_user(identifier),
         true <- to.id != from.id,
         true <- can_message?(from, to) do
      upsert_conversation(from.id, to.id)
    else
      _ -> {:error, :cannot_message}
    end
  end

  defp upsert_conversation(a_id, b_id) do
    {lo, hi} = Conversation.order_pair(a_id, b_id)

    Repo.transaction(fn ->
      conversation =
        case Repo.get_by(Conversation, user_lo_id: lo, user_hi_id: hi) do
          %Conversation{} = existing ->
            maybe_revive(existing)

          nil ->
            insert_conversation(lo, hi)
        end

      ensure_participant(conversation.id, lo)
      ensure_participant(conversation.id, hi)
      conversation
    end)
  end

  # Insert the conversation, tolerating a lost race on the unique pair index by re-fetching
  # the winner.
  defp insert_conversation(lo, hi) do
    %Conversation{}
    |> Conversation.create_changeset(%{user_lo_id: lo, user_hi_id: hi})
    |> Repo.insert()
    |> case do
      {:ok, conversation} -> conversation
      {:error, _} -> Repo.get_by!(Conversation, user_lo_id: lo, user_hi_id: hi)
    end
  end

  defp maybe_revive(%Conversation{deleted_at: nil} = conversation), do: conversation

  defp maybe_revive(%Conversation{} = conversation),
    do: Repo.update!(Ecto.Changeset.change(conversation, deleted_at: nil))

  defp ensure_participant(conversation_id, user_id) do
    case Repo.get_by(Participant, conversation_id: conversation_id, user_id: user_id) do
      nil ->
        %Participant{}
        |> Participant.create_changeset(%{conversation_id: conversation_id, user_id: user_id})
        |> Repo.insert!()

      %Participant{deleted_at: nil} = participant ->
        participant

      %Participant{} = participant ->
        Repo.update!(Ecto.Changeset.change(participant, deleted_at: nil))
    end
  end

  @doc """
  Fetches a conversation the caller participates in (participants + users preloaded), or
  `nil` (existence hidden).
  """
  def fetch_conversation(%User{} = user, id) do
    conversation =
      Repo.one(
        from c in Conversation,
          where: c.id == ^id and is_nil(c.deleted_at),
          preload: [participants: :user]
      )

    if conversation && participant?(conversation.id, user.id), do: conversation, else: nil
  end

  @doc "Lists the caller's conversations, most-recently-active first, with unread counts."
  def list_conversations(%User{id: user_id}) do
    now_participants =
      from p in Participant,
        where: p.user_id == ^user_id and is_nil(p.deleted_at)

    conversation_ids = Repo.all(from p in now_participants, select: p.conversation_id)

    conversations =
      Repo.all(
        from c in Conversation,
          where: c.id in ^conversation_ids and is_nil(c.deleted_at),
          order_by: [desc_nulls_last: c.last_message_at, desc: c.id],
          preload: [participants: :user]
      )

    unread = unread_by_conversation(user_id, conversation_ids)

    Enum.map(conversations, fn conversation ->
      %{
        conversation: conversation,
        other_user: other_user(conversation, user_id),
        unread: Map.get(unread, conversation.id, 0)
      }
    end)
  end

  @doc "The other participant's user in a conversation, from the caller's perspective."
  def other_user(%Conversation{participants: participants}, user_id)
      when is_list(participants) do
    Enum.find_value(participants, fn p -> if p.user_id != user_id, do: p.user end)
  end

  ## Messages

  @doc "Lists a conversation's live messages oldest-first, or `nil` for a non-participant."
  def list_messages(%User{} = user, %Conversation{} = conversation) do
    if participant?(conversation.id, user.id) do
      Repo.all(
        from m in Message,
          where: m.conversation_id == ^conversation.id and is_nil(m.deleted_at),
          order_by: [asc: m.inserted_at, asc: m.id]
      )
    else
      nil
    end
  end

  @doc """
  Sends a message from the caller into a conversation they participate in.

  Advances the sender's own read cursor (so it isn't unread for them), bumps
  `last_message_at`, broadcasts the message on the conversation topic, and broadcasts the
  recomputed mailbox count to the *other* participant. `{:error, :not_participant}` if the
  caller isn't in the thread.
  """
  def send_message(%User{} = user, %Conversation{} = conversation, body) do
    if participant?(conversation.id, user.id) do
      now = now()

      result =
        Repo.transaction(fn ->
          message =
            %Message{}
            |> Message.create_changeset(%{
              conversation_id: conversation.id,
              sender_id: user.id,
              body: body
            })
            |> Repo.insert()

          case message do
            {:ok, message} ->
              Repo.update_all(
                from(c in Conversation, where: c.id == ^conversation.id),
                set: [last_message_at: now, updated_at: now]
              )

              # The sender has, by definition, read their own message.
              Repo.update_all(
                from(p in Participant,
                  where: p.conversation_id == ^conversation.id and p.user_id == ^user.id
                ),
                set: [last_read_at: now, updated_at: now]
              )

              message

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)

      case result do
        {:ok, message} ->
          Phoenix.PubSub.broadcast(
            Goodmao2.PubSub,
            conversation_topic(conversation.id),
            {:message_created, message}
          )

          for participant_id <- participant_ids(conversation.id),
              participant_id != user.id,
              do: broadcast_count(participant_id)

          maybe_enqueue_message_push(message)

          {:ok, message}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      {:error, :not_participant}
    end
  end

  @doc "Advances the caller's read cursor in a conversation and refreshes their badge."
  def mark_conversation_read(%User{} = user, %Conversation{} = conversation) do
    if participant?(conversation.id, user.id) do
      now = now()

      {count, _} =
        Repo.update_all(
          from(p in Participant,
            where: p.conversation_id == ^conversation.id and p.user_id == ^user.id
          ),
          set: [last_read_at: now, updated_at: now]
        )

      if count > 0, do: broadcast_count(user.id)
      {:ok, count}
    else
      {:error, :not_participant}
    end
  end

  ## Web Push (ADR-0011 Stage 2)

  # A new message surfaces on the mailbox badge and (if configured) as a Web Push to the
  # other participant — messages write no bell row, so this is their only push path.
  defp maybe_enqueue_message_push(%Message{id: id}) do
    if WebPush.vapid_configured?() do
      %{"message_id" => id}
      |> MessagePushWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  Delivers a message to the *other* participant's browsers as Web Push.

  The `MessagePushWorker` entry point: renders the sender + body into a payload (deep-linking
  to the thread) and sends to the recipient's live subscriptions. No-op if the message is
  gone/soft-deleted or the recipient has no subscriptions.
  """
  def dispatch_message_push(message_id) do
    case Repo.get(Message, message_id) do
      %Message{deleted_at: nil} = message ->
        recipient_ids = participant_ids(message.conversation_id) -- [message.sender_id]

        if recipient_ids != [] do
          sender = Repo.get(User, message.sender_id)

          payload =
            Goodmao2Web.Helpers.message_push_payload(
              sender,
              message.body,
              message.conversation_id
            )

          Enum.each(recipient_ids, &Notifications.push_to_user(&1, payload))
        end

        :ok

      _ ->
        :ok
    end
  end

  ## Unread counts

  @doc "The caller's total unread message count across all conversations — the badge."
  def unread_count(%User{id: user_id}), do: unread_count(user_id)

  def unread_count(user_id) when is_integer(user_id) do
    Repo.one(unread_query(user_id) |> exclude(:group_by) |> select([m], count(m.id))) || 0
  end

  defp unread_by_conversation(user_id, _conversation_ids) do
    unread_query(user_id)
    |> select([m, p], {m.conversation_id, count(m.id)})
    |> Repo.all()
    |> Map.new()
  end

  # Live messages in the caller's non-left conversations, sent by someone else, arriving
  # after the caller's read cursor. Grouped by conversation.
  defp unread_query(user_id) do
    from m in Message,
      join: p in Participant,
      on: p.conversation_id == m.conversation_id,
      where: p.user_id == ^user_id and is_nil(p.deleted_at),
      where: is_nil(m.deleted_at) and m.sender_id != ^user_id,
      where: is_nil(p.last_read_at) or m.inserted_at > p.last_read_at,
      group_by: m.conversation_id
  end

  ## Helpers

  defp participant?(conversation_id, user_id) do
    Repo.exists?(
      from p in Participant,
        where:
          p.conversation_id == ^conversation_id and p.user_id == ^user_id and
            is_nil(p.deleted_at)
    )
  end

  defp participant_ids(conversation_id) do
    Repo.all(
      from p in Participant,
        where: p.conversation_id == ^conversation_id and is_nil(p.deleted_at),
        select: p.user_id
    )
  end

  defp broadcast_count(user_id) do
    Phoenix.PubSub.broadcast(
      Goodmao2.PubSub,
      topic(user_id),
      {:messages_changed, %{unread: unread_count(user_id)}}
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
