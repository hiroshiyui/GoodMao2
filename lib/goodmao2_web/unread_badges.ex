defmodule Goodmao2Web.UnreadBadges do
  @moduledoc """
  A LiveView `on_mount` hook that keeps the nav's unread badges — and the signed-in user's own
  avatar — live across **every** authenticated LiveView, with no per-LiveView code.

  On mount it assigns the current unread notification and message counts plus the user's avatar
  meta (`@current_user_avatar`, for the nav avatar). On the connected socket it subscribes to the
  user's notification, message, and avatar PubSub topics and attaches a process-level
  `:handle_info` hook: `{:notifications_changed, …}` / `{:messages_changed, …}` update the badge
  assign and **halt** (individual LiveViews never see them); `{:avatar_updated, "user", …}` updates
  the nav avatar but **passes through** (`:cont`) so a LiveView that also tracks its own avatar
  (e.g. `/users/settings`) still reacts; every other message passes through. Added to the
  `:require_authenticated_user` live_session's `on_mount` list.
  """
  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

  alias Goodmao2.{Messaging, Notifications}
  alias Goodmao2.Media.Avatars

  def on_mount(:mount_badges, _params, _session, socket) do
    user = socket.assigns.current_scope && socket.assigns.current_scope.user

    if user do
      {:cont, mount_for(socket, user)}
    else
      {:cont, socket}
    end
  end

  defp mount_for(socket, user) do
    socket =
      socket
      |> assign_new(:unread_notifications, fn -> Notifications.unread_count(user) end)
      |> assign_new(:unread_messages, fn -> Messaging.unread_count(user) end)
      |> assign_new(:current_user_avatar, fn -> Avatars.meta("user", user.id) end)

    if connected?(socket) do
      Notifications.subscribe(user)
      Messaging.subscribe(user)
      Avatars.subscribe_user(user.id)

      attach_hook(socket, :unread_badges, :handle_info, &handle_badge_message/2)
    else
      socket
    end
  end

  defp handle_badge_message({:notifications_changed, %{unread: n}}, socket),
    do: {:halt, assign(socket, :unread_notifications, n)}

  defp handle_badge_message({:messages_changed, %{unread: n}}, socket),
    do: {:halt, assign(socket, :unread_messages, n)}

  # Keep the nav avatar live, but pass through so a LiveView tracking its own avatar still reacts.
  defp handle_badge_message({:avatar_updated, "user", _id, meta}, socket),
    do: {:cont, assign(socket, :current_user_avatar, avatar_or_nil(meta))}

  defp handle_badge_message(_message, socket), do: {:cont, socket}

  defp avatar_or_nil(%{status: "ready"} = meta), do: meta
  defp avatar_or_nil(_), do: nil
end
