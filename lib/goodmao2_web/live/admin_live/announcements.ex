defmodule Goodmao2Web.AdminLive.Announcements do
  @moduledoc """
  Admin-only announcement compose page: broadcast a titled message to every user as an
  `announcement` notification (fanned out via Oban). A sibling of `AdminLive`, gated by the
  same `:require_admin` on_mount (non-admins are silently sent home, IDOR-hidden).
  """
  use Goodmao2Web, :live_view

  on_mount {Goodmao2Web.UserAuth, :require_admin}

  alias Goodmao2.Notifications

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Announcements"))
     |> assign(:form, to_form(%{"title" => "", "body" => ""}, as: :announcement))}
  end

  @impl true
  def handle_event("broadcast", %{"announcement" => %{"title" => title, "body" => body}}, socket) do
    admin = socket.assigns.current_scope.user

    cond do
      String.trim(title) == "" or String.trim(body) == "" ->
        {:noreply,
         put_flash(socket, :error, gettext("An announcement needs both a title and a body."))}

      true ->
        case Notifications.broadcast_announcement(admin, %{title: title, body: body}) do
          {:ok, _job} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Announcement sent to all users."))
             |> assign(:form, to_form(%{"title" => "", "body" => ""}, as: :announcement))}

          {:error, :unauthorized} ->
            {:noreply, push_navigate(socket, to: ~p"/")}
        end
    end
  end

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
        id="announcements-section"
        aria-labelledby="announcements-heading"
        class="mx-auto max-w-xl"
      >
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/admin"}
            id="announcements-back"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Back")}
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 id="announcements-heading" class="text-2xl font-semibold">
            {gettext("Post an announcement")}
          </h1>
        </div>

        <p class="text-base-content/60 mt-2 text-sm">
          {gettext("Every user receives this as a notification. Use it sparingly.")}
        </p>

        <.form
          for={@form}
          id="announcement-form"
          phx-submit="broadcast"
          class="card card-border bg-base-100 mt-4"
        >
          <div class="card-body space-y-3 p-4">
            <.input field={@form[:title]} type="text" label={gettext("Title")} required />
            <.input field={@form[:body]} type="textarea" label={gettext("Message")} rows="4" required />
            <.button
              type="submit"
              id="announcement-submit"
              class="btn btn-primary w-fit"
              phx-disable-with={gettext("Sending…")}
            >
              {gettext("Send to everyone")}
            </.button>
          </div>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
