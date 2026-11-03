defmodule Goodmao2.Notifications do
  @moduledoc """
  The Notifications context: the in-site event feed (the "bell").

  A notification is a per-recipient row with a stable `type` and a denormalized `jsonb`
  `payload`; the display sentence is **rendered** from those at read time
  (`Goodmao2Web.Helpers.notification_summary/1`), never stored. Each row is scoped to one
  user, so reads/mutations authorize purely by recipient ownership — an IDOR read returns
  `nil`; a mutation on a row the caller doesn't own returns `{:error, :not_found}`.

  Single-recipient events (`access_granted`/`access_revoked`) are created **inline** by the
  `Pets` context. Many-recipient events fan out through Oban:
  `log_added` (every other follower who may view the entry) via
  `Goodmao2.Notifications.LogFanoutWorker`, and admin `announcement`s via
  `Goodmao2.Notifications.AnnouncementFanoutWorker`.

  `Medications.ReminderWorker` creates `medication_due` the same way, and the media pipeline
  creates `media_failed` / `avatar_failed` when a purify job rejects an upload — seven types
  in all (see `Notification.types/0`, the canonical list).

  Unread counts are kept live over PubSub: every change broadcasts the **recomputed**
  absolute unread count on the recipient's topic, so at-least-once fan-out retries can't
  drift the badge. Notifications are soft-deleted (`deleted_at`); `read_at` marks read.

  **Web Push** (ADR-0011 Stage 2) rides these same rows rather than forming a parallel
  system: every bell row funnels through `create/3`, which enqueues a `PushDispatchWorker`
  when `WebPush.vapid_configured?/0`. The worker re-reads the row and skips a **deleted**
  one, so dismissing a notification before a backed-up queue drains also cancels its push.
  """
  import Ecto.Query, warn: false

  alias Goodmao2.Repo
  alias Goodmao2.Accounts.User
  alias Goodmao2.Notifications.Notification
  alias Goodmao2.Notifications.PushDispatchWorker
  alias Goodmao2.Notifications.PushSubscription
  alias Goodmao2.Notifications.WebPush

  @default_limit 50

  ## PubSub

  @topic_prefix "user_notifications:"

  @doc "The PubSub topic carrying a user's notification-count updates."
  def topic(%User{id: id}), do: topic(id)
  def topic(user_id), do: @topic_prefix <> to_string(user_id)

  @doc "Subscribes the caller to a user's notification-count updates."
  def subscribe(user_or_id), do: Phoenix.PubSub.subscribe(Goodmao2.PubSub, topic(user_or_id))

  ## Reads

  @doc "Lists a user's live notifications, newest first (`:limit`, default 50)."
  def list_notifications(%User{id: user_id}, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    Repo.all(
      from n in Notification,
        where: n.user_id == ^user_id and is_nil(n.deleted_at),
        order_by: [desc: n.inserted_at, desc: n.id],
        limit: ^limit
    )
  end

  @doc "Counts a user's live, unread notifications — drives the bell badge."
  def unread_count(%User{id: user_id}), do: unread_count(user_id)

  def unread_count(user_id) when is_integer(user_id) do
    Repo.one(
      from n in Notification,
        where: n.user_id == ^user_id and is_nil(n.deleted_at) and is_nil(n.read_at),
        select: count(n.id)
    )
  end

  @doc "Fetches one of the caller's live notifications, or `nil` (IDOR-hidden)."
  def get_notification(%User{id: user_id}, id) do
    case Goodmao2.ID.normalize(id) do
      {:ok, id} ->
        Repo.one(
          from n in Notification,
            where: n.id == ^id and n.user_id == ^user_id and is_nil(n.deleted_at)
        )

      :error ->
        nil
    end
  end

  ## Mutations (recipient-only)

  @doc "Marks one of the caller's notifications read. No-op if already read/absent."
  def mark_read(%User{} = user, %Notification{} = notification) do
    mark_read(user, notification.id)
  end

  def mark_read(%User{id: user_id} = user, id) do
    case Goodmao2.ID.normalize(id) do
      {:ok, id} ->
        {count, _} =
          Repo.update_all(
            from(n in Notification,
              where: n.id == ^id and n.user_id == ^user_id and is_nil(n.read_at),
              where: is_nil(n.deleted_at)
            ),
            set: [read_at: now(), updated_at: now()]
          )

        if count > 0, do: broadcast_count(user)
        {:ok, count}

      :error ->
        {:ok, 0}
    end
  end

  @doc "Marks all of the caller's unread notifications read."
  def mark_all_read(%User{id: user_id} = user) do
    {count, _} =
      Repo.update_all(
        from(n in Notification,
          where: n.user_id == ^user_id and is_nil(n.read_at) and is_nil(n.deleted_at)
        ),
        set: [read_at: now(), updated_at: now()]
      )

    if count > 0, do: broadcast_count(user)
    {:ok, count}
  end

  @doc "Soft-deletes one of the caller's notifications."
  def delete_notification(%User{} = user, %Notification{} = notification) do
    if notification.user_id == user.id do
      notification
      |> Ecto.Changeset.change(deleted_at: now())
      |> Repo.update()
      |> tap(fn _ -> broadcast_count(user) end)
    else
      {:error, :not_found}
    end
  end

  ## Creation (called by contexts / workers — not user-facing)

  @doc """
  Creates a notification for `user_id` and broadcasts the recipient's fresh unread count.

  Low-level entry point used by the inline notifiers below and the fan-out workers.
  """
  def create(user_id, type, payload) do
    %Notification{}
    |> Notification.create_changeset(%{user_id: user_id, type: type, payload: payload})
    |> Repo.insert()
    |> case do
      {:ok, notification} ->
        broadcast_count(user_id)
        maybe_enqueue_push(notification)
        {:ok, notification}

      error ->
        error
    end
  end

  ## Web Push (ADR-0011 Stage 2)

  # Every bell row funnels through create/3, so one enqueue here covers all four types —
  # the inline grant/revoke notifiers and both fan-out workers. Gated on VAPID config so the
  # feature stays dormant (dev/test default) until an admin generates keys on /admin/settings.
  defp maybe_enqueue_push(%Notification{id: id}) do
    if WebPush.vapid_configured?() do
      %{"notification_id" => id}
      |> PushDispatchWorker.new()
      |> Oban.insert()
    end
  end

  @doc """
  Delivers a stored notification to its recipient's browsers as Web Push.

  The `PushDispatchWorker` entry point: loads the (live) notification and the recipient's
  live subscriptions, renders the payload once, and sends to each. No-op if the notification
  is gone or the user has no subscriptions.
  """
  def dispatch_web_push(notification_id) do
    # "Live" means non-deleted: the job is queued separately from the row, so a user who
    # dismisses a notification before a backed-up queue drains (or before an Oban retry)
    # would otherwise still get the phone push for something they already cleared.
    query =
      from n in Notification,
        where: n.id == ^notification_id and is_nil(n.deleted_at)

    case Repo.one(query) do
      %Notification{} = notification ->
        push_to_user(notification.user_id, WebPush.build_payload(notification))

      _ ->
        :ok
    end
  end

  @doc """
  Sends an already-built payload map to every live push subscription of `user_id`.

  The generic Web Push primitive — used by `dispatch_web_push/1` (bell notifications) and by
  `Goodmao2.Messaging` (new mailbox messages, which write no bell row). No-op if the user
  has no subscriptions. Best-effort; a `410` prunes the stale subscription.
  """
  def push_to_user(user_id, payload) when is_map(payload) do
    case live_push_subscriptions(user_id) do
      [] ->
        :ok

      subscriptions ->
        json = Jason.encode!(payload)
        Enum.each(subscriptions, &WebPush.send_web_push(&1, json))
        :ok
    end
  end

  defp live_push_subscriptions(user_id) do
    Repo.all(
      from s in PushSubscription,
        where: s.user_id == ^user_id and is_nil(s.deleted_at)
    )
  end

  @doc """
  Registers (or refreshes) a browser push subscription for `user`.

  Endpoints are globally unique. If the endpoint is new, it is inserted; if it already
  belongs to `user`, its keys are refreshed and any soft-delete is reversed (re-subscribe).
  A **soft-deleted** row of another user is re-claimed: that user logged out or unsubscribed,
  and the endpoint is a capability only the browser holding it can present. A **live** row of
  another user is `{:error, :endpoint_conflict}`. The endpoint is SSRF-validated by the
  changeset before it can be stored.
  """
  def upsert_push_subscription(user, attrs, session_token \\ nil)

  def upsert_push_subscription(%User{} = user, %{endpoint: endpoint} = attrs, session_token)
      when is_binary(endpoint) do
    attrs = Map.put(attrs, :user_id, user.id)
    session_hash = session_token && session_token_hash(session_token)

    case Repo.get_by(PushSubscription, endpoint: endpoint) do
      nil ->
        %PushSubscription{}
        |> PushSubscription.changeset(attrs)
        |> Ecto.Changeset.put_change(:session_token_hash, session_hash)
        |> Repo.insert()

      %PushSubscription{user_id: uid, deleted_at: deleted_at} = existing
      when uid == user.id or not is_nil(deleted_at) ->
        existing
        |> PushSubscription.changeset(attrs)
        |> Ecto.Changeset.put_change(:session_token_hash, session_hash)
        |> Ecto.Changeset.put_change(:deleted_at, nil)
        |> Repo.update()

      %PushSubscription{} ->
        {:error, :endpoint_conflict}
    end
  end

  # A missing or non-string endpoint never reaches the lookup (Ecto refuses a nil comparison
  # and cannot cast a map): it is a validation error like any other.
  def upsert_push_subscription(%User{} = user, attrs, _session_token) do
    {:error,
     %PushSubscription{}
     |> PushSubscription.changeset(attrs |> Map.delete(:endpoint) |> Map.put(:user_id, user.id))}
  end

  @doc "Whether `endpoint` is a live subscription of `user` (a browser checking its own state)."
  def push_subscription_active?(%User{id: user_id}, endpoint) when is_binary(endpoint) do
    Repo.exists?(
      from s in PushSubscription,
        where: s.endpoint == ^endpoint and s.user_id == ^user_id and is_nil(s.deleted_at)
    )
  end

  @doc "Soft-deletes `user`'s subscription for `endpoint`, or `{:error, :not_found}`."
  def delete_push_subscription(%User{} = user, endpoint) when is_binary(endpoint) do
    case Repo.get_by(PushSubscription, endpoint: endpoint, user_id: user.id) do
      nil -> {:error, :not_found}
      %PushSubscription{} = subscription -> soft_delete_subscription(subscription)
    end
  end

  @doc """
  Soft-deletes every live subscription registered through one of `session_tokens`. Called
  whenever sessions are revoked (log-out, and the revocations behind
  `Goodmao2Web.UserAuth.disconnect_sessions/1`): the endpoint belongs to the device, so leaving
  it live would keep pushing to a lost phone, or to the next person to sign in there. `:ok`.
  """
  def release_push_subscriptions(session_tokens) when is_list(session_tokens) do
    hashes = for token <- session_tokens, is_binary(token), do: session_token_hash(token)

    if hashes != [] do
      Repo.update_all(
        from(s in PushSubscription,
          where: s.session_token_hash in ^hashes and is_nil(s.deleted_at)
        ),
        set: [deleted_at: now()]
      )
    end

    :ok
  end

  @doc """
  Moves `user_id`'s subscriptions from one session token to its replacement — a token
  reissue, a sudo re-authentication, or a password change keeps the device signed in under a
  new token, and its subscription must follow, or a later revocation would miss it. `:ok`.
  """
  def rebind_push_subscriptions(user_id, old_token, new_token)
      when is_integer(user_id) and is_binary(old_token) and is_binary(new_token) do
    Repo.update_all(
      from(s in PushSubscription,
        where: s.user_id == ^user_id and s.session_token_hash == ^session_token_hash(old_token)
      ),
      set: [session_token_hash: session_token_hash(new_token)]
    )

    :ok
  end

  defp session_token_hash(token), do: :crypto.hash(:sha256, token)

  defp soft_delete_subscription(subscription) do
    subscription
    |> Ecto.Changeset.change(deleted_at: now())
    |> Repo.update()
  end

  @doc "Inline single-recipient notification that `actor` granted `role` on `pet`."
  def notify_access_granted(grantee_id, %User{} = actor, pet, role) do
    create(grantee_id, "access_granted", %{
      "pet_id" => pet.id,
      "pet_name" => pet.name,
      "actor" => actor_label(actor),
      "role" => role
    })
  end

  @doc "Inline single-recipient notification that `actor` revoked access to `pet`."
  def notify_access_revoked(grantee_id, %User{} = actor, pet) do
    create(grantee_id, "access_revoked", %{
      "pet_id" => pet.id,
      "pet_name" => pet.name,
      "actor" => actor_label(actor)
    })
  end

  ## Fan-out (Oban)

  @doc """
  Enqueues the `log_added` fan-out for a newly created entry.

  Called from the log write paths (`Logs.create_entry/3` and the media life-log path). The
  recipient set is resolved asynchronously in `LogFanoutWorker` so the write stays fast.
  """
  def enqueue_log_fanout(pet_id, entry_id) do
    %{"pet_id" => pet_id, "entry_id" => entry_id}
    |> Goodmao2.Notifications.LogFanoutWorker.new()
    |> Oban.insert()
  end

  ## Fan-out (Oban worker entry points)

  @doc """
  Fans a `log_added` event out to every *other* effective follower of the pet who may
  view the entry (per-entry `visibility`, ADR-0004). Idempotency is best-effort — the ADR
  accepts that an Oban retry may double-post.
  """
  def fan_out_log_added(pet_id, entry_id) do
    entry = Goodmao2.Logs.get_entry_for_fanout(entry_id)
    pet = entry && Goodmao2.Repo.get(Goodmao2.Pets.Pet, pet_id)

    # `pet` is loaded fresh here, so its `history_hidden` is current: the owner may have hidden
    # the history since the entry was created, and a bell naming the pet and log type would
    # then be the only thing a grantee still sees of it.
    if entry && pet && entry.pet_id == pet.id && not pet.history_hidden do
      actor_id = entry.recorded_by_user_id

      recipients =
        pet
        |> Goodmao2.Pets.list_effective_accesses()
        |> Enum.reject(fn access -> access.user_id == actor_id end)
        |> Enum.filter(fn access ->
          Goodmao2.Logs.can_view_entry?(entry, access.user_id, access.role)
        end)

      payload = %{
        "pet_id" => pet.id,
        "pet_name" => pet.name,
        "entry_id" => entry.id,
        "log_type" => entry.type
      }

      for access <- recipients, do: create(access.user_id, "log_added", payload)
      :ok
    else
      :ok
    end
  end

  @doc "Fans an admin announcement out to every user."
  def fan_out_announcement(payload) do
    payload = Map.new(payload, fn {k, v} -> {to_string(k), v} end)

    Goodmao2.Accounts.all_user_ids()
    |> Enum.each(fn user_id -> create(user_id, "announcement", payload) end)

    :ok
  end

  @doc """
  Enqueues an admin announcement for fan-out. Admin-only.

  Stores the sending admin's id in the payload for audit; the copy renders a neutral
  system label. Returns `{:error, :unauthorized}` for a non-admin.
  """
  def broadcast_announcement(%User{is_admin: true} = admin, %{title: title, body: body}) do
    %{"title" => title, "body" => body, "admin_id" => admin.id}
    |> Goodmao2.Notifications.AnnouncementFanoutWorker.new()
    |> Oban.insert()
  end

  def broadcast_announcement(%User{}, _attrs), do: {:error, :unauthorized}

  ## Helpers

  # A non-leaking public label for an actor: handle, then display name, else nil (the
  # renderer shows a generic "Someone"). Never the email.
  defp actor_label(%User{handle: handle}) when is_binary(handle) and handle != "",
    do: "@" <> handle

  defp actor_label(%User{display_name: name}) when is_binary(name) and name != "", do: name
  defp actor_label(%User{}), do: nil

  defp broadcast_count(%User{id: user_id}), do: broadcast_count(user_id)

  defp broadcast_count(user_id) when is_integer(user_id) do
    Phoenix.PubSub.broadcast(
      Goodmao2.PubSub,
      topic(user_id),
      {:notifications_changed, %{unread: unread_count(user_id)}}
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
