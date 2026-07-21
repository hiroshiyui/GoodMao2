defmodule Goodmao2Web.UnreadBadges do
  @moduledoc """
  A LiveView `on_mount` hook that keeps the nav's unread badges live across **every**
  authenticated LiveView, with no per-LiveView code.

  On mount it assigns the current unread notification and message counts. On the connected
  socket it subscribes to the user's notification and message PubSub topics and attaches a
  process-level `:handle_info` hook: any `{:notifications_changed, …}` / `{:messages_changed, …}`
  broadcast updates the corresponding assign and halts (so individual LiveViews never see
  those messages), while every other message passes through (`:cont`) to the LiveView's own
  `handle_info`. Added to the `:require_authenticated_user` live_session's `on_mount` list.
  """
  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView, only: [connected?: 1, attach_hook: 4]

  alias Goodmao2.{Messaging, Notifications}

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

    if connected?(socket) do
      Notifications.subscribe(user)
      Messaging.subscribe(user)

      attach_hook(socket, :unread_badges, :handle_info, &handle_badge_message/2)
    else
      socket
    end
  end

  defp handle_badge_message({:notifications_changed, %{unread: n}}, socket),
    do: {:halt, assign(socket, :unread_notifications, n)}

  defp handle_badge_message({:messages_changed, %{unread: n}}, socket),
    do: {:halt, assign(socket, :unread_messages, n)}

  defp handle_badge_message(_message, socket), do: {:cont, socket}
end
