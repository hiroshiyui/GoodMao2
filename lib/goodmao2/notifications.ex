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

  Unread counts are kept live over PubSub: every change broadcasts the **recomputed**
  absolute unread count on the recipient's topic, so at-least-once fan-out retries can't
  drift the badge. Notifications are soft-deleted (`deleted_at`); `read_at` marks read.
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
    Repo.one(
      from n in Notification,
        where: n.id == ^id and n.user_id == ^user_id and is_nil(n.deleted_at)
    )
  end

  ## Mutations (recipient-only)

  @doc "Marks one of the caller's notifications read. No-op if already read/absent."
  def mark_read(%User{} = user, %Notification{} = notification) do
    mark_read(user, notification.id)
  end

  def mark_read(%User{id: user_id} = user, id) do
    {count, _} =
      Repo.update_all(
        from(n in Notification,
          where: n.id == ^id and n.user_id == ^user_id and is_nil(n.read_at)
        ),
        set: [read_at: now(), updated_at: now()]
      )

    if count > 0, do: broadcast_count(user)
    {:ok, count}
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
    with %Notification{} = notification <- Repo.get(Notification, notification_id),
         [_ | _] = subscriptions <- live_push_subscriptions(notification.user_id) do
      payload = notification |> WebPush.build_payload() |> Jason.encode!()
      Enum.each(subscriptions, &WebPush.send_web_push(&1, payload))
      :ok
    else
      _ -> :ok
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
  belongs to `user`, its keys are refreshed and any soft-delete is reversed (re-subscribe);
  if it belongs to **another** user, `{:error, :endpoint_conflict}`. The endpoint is
  SSRF-validated by the changeset before it can be stored.
  """
  def upsert_push_subscription(%User{} = user, attrs) do
    attrs = Map.put(attrs, :user_id, user.id)

    case Repo.get_by(PushSubscription, endpoint: attrs.endpoint) do
      nil ->
        %PushSubscription{}
        |> PushSubscription.changeset(attrs)
        |> Repo.insert()

      %PushSubscription{user_id: uid} = existing when uid == user.id ->
        existing
        |> PushSubscription.changeset(attrs)
        |> Ecto.Changeset.put_change(:deleted_at, nil)
        |> Repo.update()

      %PushSubscription{} ->
        {:error, :endpoint_conflict}
    end
  end

  @doc "Soft-deletes `user`'s subscription for `endpoint`, or `{:error, :not_found}`."
  def delete_push_subscription(%User{} = user, endpoint) when is_binary(endpoint) do
    case Repo.get_by(PushSubscription, endpoint: endpoint, user_id: user.id) do
      nil ->
        {:error, :not_found}

      %PushSubscription{} = subscription ->
        subscription
        |> Ecto.Changeset.change(deleted_at: now())
        |> Repo.update()
    end
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

    if entry && pet && entry.pet_id == pet.id do
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
