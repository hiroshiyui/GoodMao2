defmodule Goodmao2Web.MessageLive.Index do
  @moduledoc """
  The mailbox inbox: the caller's conversations, most-recently-active first, each showing
  the other participant and an unread count. A "New message" form starts a conversation by
  `@handle`/email — gated by the shared-pet rule, with a single non-leaking error. Live
  over PubSub: an arriving message re-orders and re-counts the list.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Messaging

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    if connected?(socket), do: Messaging.subscribe(user)

    {:ok,
     socket
     |> assign(:page_title, gettext("Messages"))
     |> assign(:compose_form, to_form(%{"identifier" => ""}, as: :compose))
     |> load_conversations()}
  end

  defp load_conversations(socket) do
    user = socket.assigns.current_scope.user
    assign(socket, :conversations, Messaging.list_conversations(user))
  end

  @impl true
  def handle_event("start", %{"compose" => %{"identifier" => identifier}}, socket) do
    user = socket.assigns.current_scope.user

    case Messaging.start_conversation(user, identifier) do
      {:ok, conversation} ->
        {:noreply, push_navigate(socket, to: ~p"/messages/#{conversation.id}")}

      {:error, :cannot_message} ->
        # Uniform, non-leaking: never reveal whether the recipient exists (ADR-0007).
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "We couldn't start that conversation. You can only message people you share a pet with."
           )
         )}
    end
  end

  @impl true
  def handle_info({:messages_changed, _payload}, socket) do
    {:noreply, load_conversations(socket)}
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
    >
      <section id="messages-section" aria-labelledby="messages-heading" class="mx-auto max-w-xl">
        <h1 id="messages-heading" class="text-2xl font-semibold">{gettext("Messages")}</h1>

        <.form
          for={@compose_form}
          id="compose-form"
          phx-submit="start"
          class="card card-border bg-base-100 mt-4"
        >
          <div class="card-body flex-row items-end gap-3 p-4">
            <div class="flex-1">
              <.input
                field={@compose_form[:identifier]}
                type="text"
                label={gettext("Message someone (@handle or email)")}
                required
              />
            </div>
            <.button type="submit" id="compose-submit" class="btn btn-primary">
              {gettext("Start")}
            </.button>
          </div>
        </.form>

        <ul id="conversations-list" class="mt-6 space-y-2">
          <li
            :if={@conversations == []}
            id="conversations-empty"
            class="text-base-content/60 py-8 text-center"
          >
            {gettext("No conversations yet. Start one with someone you share a pet with.")}
          </li>
          <li
            :for={entry <- @conversations}
            id={"conversation-#{entry.conversation.id}"}
            class="conversation-row card card-border bg-base-100"
          >
            <.link navigate={~p"/messages/#{entry.conversation.id}"} class="block hover:opacity-80">
              <div class="card-body flex-row items-center justify-between gap-3 p-3">
                <div class="min-w-0">
                  <p class="conversation-other font-medium break-words">
                    {Layouts.account_label(entry.other_user)}
                  </p>
                  <p
                    :if={entry.conversation.last_message_at}
                    class="conversation-time text-base-content/50 text-xs"
                  >
                    {format_datetime(entry.conversation.last_message_at)}
                  </p>
                </div>
                <span
                  :if={entry.unread > 0}
                  class="conversation-unread badge badge-primary badge-sm"
                  aria-label={
                    ngettext("%{count} unread message", "%{count} unread messages", entry.unread,
                      count: entry.unread
                    )
                  }
                >
                  {entry.unread}
                </span>
              </div>
            </.link>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
