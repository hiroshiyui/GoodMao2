defmodule Goodmao2Web.NotificationLive.Index do
  @moduledoc """
  The notification feed (the "bell"): a user's recent events, newest first. Each row's
  copy is rendered from its stored `type` + payload (`Goodmao2Web.Helpers`), links to its
  target, and can be marked read or dismissed. Live over PubSub — a new notification for
  this user streams in without a reload.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Notifications

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    if connected?(socket), do: Notifications.subscribe(user)

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     |> stream(:notifications, Notifications.list_notifications(user))}
  end

  @impl true
  def handle_event("mark_read", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    with %{} = notification <- Notifications.get_notification(user, id) do
      {:ok, _} = Notifications.mark_read(user, notification)
      {:noreply, stream_insert(socket, :notifications, %{notification | read_at: now()})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("mark_all_read", _params, socket) do
    user = socket.assigns.current_scope.user
    {:ok, _} = Notifications.mark_all_read(user)
    # Re-stream so every row reflects its read state.
    {:noreply,
     stream(socket, :notifications, Notifications.list_notifications(user), reset: true)}
  end

  def handle_event("dismiss", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    with %{} = notification <- Notifications.get_notification(user, id) do
      {:ok, _} = Notifications.delete_notification(user, notification)
      {:noreply, stream_delete(socket, :notifications, notification)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:notifications_changed, _payload}, socket) do
    # A new notification arrived for this user (e.g. a fan-out) — refresh the list.
    user = socket.assigns.current_scope.user

    {:noreply,
     stream(socket, :notifications, Notifications.list_notifications(user), reset: true)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
      current_user_avatar={@current_user_avatar}
    >
      <section
        id="notifications-section"
        aria-labelledby="notifications-heading"
        class="mx-auto max-w-xl"
      >
        <div class="flex items-center justify-between gap-2">
          <h1 id="notifications-heading" class="text-2xl font-semibold">
            {gettext("Notifications")}
          </h1>
          <button
            type="button"
            id="mark-all-read"
            phx-click="mark_all_read"
            class="btn btn-ghost btn-sm"
          >
            {gettext("Mark all read")}
          </button>
        </div>

        <ul id="notifications-list" phx-update="stream" class="mt-4 space-y-2">
          <li
            class="hidden only:block text-base-content/60 py-8 text-center"
            id="notifications-empty"
          >
            {gettext(
              "Nothing yet. You'll hear about access changes, new logs, and announcements here."
            )}
          </li>
          <li
            :for={{dom_id, notification} <- @streams.notifications}
            id={dom_id}
            class={[
              "notification-row card card-border bg-base-100",
              is_nil(notification.read_at) && "border-primary/40"
            ]}
          >
            <div class="card-body flex-row items-start gap-3 p-3">
              <.icon
                name={notification_icon(notification.type)}
                class="text-base-content/70 mt-0.5 size-5"
              />
              <div class="min-w-0 flex-1">
                <.dynamic_link notification={notification}>
                  <p class="notification-title font-medium">
                    {notification_title(notification)}
                    <span
                      :if={is_nil(notification.read_at)}
                      class="notification-unread-dot badge badge-primary badge-xs align-middle"
                      aria-label={gettext("Unread")}
                    />
                  </p>
                  <p class="notification-summary text-base-content/70 text-sm break-words">
                    {notification_summary(notification)}
                  </p>
                </.dynamic_link>
                <p class="notification-time text-base-content/50 mt-1 text-xs">
                  {format_datetime(notification.inserted_at)}
                </p>
              </div>
              <div class="flex flex-none gap-1">
                <button
                  :if={is_nil(notification.read_at)}
                  type="button"
                  id={"mark-read-#{notification.id}"}
                  phx-click="mark_read"
                  phx-value-id={notification.id}
                  class="btn btn-ghost btn-xs"
                >
                  {gettext("Mark read")}
                </button>
                <button
                  type="button"
                  id={"dismiss-#{notification.id}"}
                  phx-click="dismiss"
                  phx-value-id={notification.id}
                  aria-label={gettext("Dismiss")}
                  class="btn btn-ghost btn-xs btn-circle"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </div>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  # Wraps a notification's body in a link to its target when it has one; otherwise renders
  # the body inline (e.g. announcements aren't navigable).
  attr :notification, :map, required: true
  slot :inner_block, required: true

  defp dynamic_link(assigns) do
    assigns = assign(assigns, :path, notification_path(assigns.notification))

    ~H"""
    <.link :if={@path} navigate={@path} class="block hover:opacity-80">
      {render_slot(@inner_block)}
    </.link>
    <div :if={is_nil(@path)}>{render_slot(@inner_block)}</div>
    """
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
