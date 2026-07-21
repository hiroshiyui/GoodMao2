defmodule Goodmao2Web.MessageLive.Show do
  @moduledoc """
  A single conversation thread: the messages oldest-first plus a compose box. Reachable
  only by a participant — a non-participant (or unknown id) is redirected as "not found"
  (existence hidden, ADR-0007). Live over PubSub: the other person's messages append in
  real time, and opening/reading advances the caller's read cursor.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Messaging
  alias Goodmao2.Messaging.Message

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user

    case Messaging.fetch_conversation(user, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Conversation not found."))
         |> push_navigate(to: ~p"/messages")}

      conversation ->
        if connected?(socket), do: Messaging.subscribe_conversation(conversation)
        {:ok, _} = Messaging.mark_conversation_read(user, conversation)
        other = Messaging.other_user(conversation, user.id)

        {:ok,
         socket
         |> assign(:page_title, gettext("Chat with %{name}", name: Layouts.account_label(other)))
         |> assign(:conversation, conversation)
         |> assign(:other_user, other)
         |> assign(:compose_form, to_form(%{"body" => ""}, as: :message))
         |> stream(:messages, Messaging.list_messages(user, conversation))}
    end
  end

  @impl true
  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    user = socket.assigns.current_scope.user

    case Messaging.send_message(user, socket.assigns.conversation, body) do
      {:ok, message} ->
        {:noreply,
         socket
         |> stream_insert(:messages, message)
         |> assign(:compose_form, to_form(%{"body" => ""}, as: :message))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Your message couldn't be sent."))}

      {:error, :not_participant} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Conversation not found."))
         |> push_navigate(to: ~p"/messages")}
    end
  end

  @impl true
  def handle_info({:message_created, %Message{} = message}, socket) do
    # Only messages for this thread, and re-mark read since the reader is looking at it.
    if message.conversation_id == socket.assigns.conversation.id do
      user = socket.assigns.current_scope.user
      {:ok, _} = Messaging.mark_conversation_read(user, socket.assigns.conversation)
      {:noreply, stream_insert(socket, :messages, message)}
    else
      {:noreply, socket}
    end
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
      <section
        id="message-thread-section"
        aria-labelledby="message-thread-heading"
        class="mx-auto max-w-xl"
      >
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/messages"}
            id="thread-back"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Back")}
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 id="message-thread-heading" class="text-2xl font-semibold break-words">
            {Layouts.account_label(@other_user)}
          </h1>
        </div>

        <ol id="message-thread" phx-update="stream" class="mt-6 space-y-2">
          <li
            class="hidden only:block text-base-content/60 py-8 text-center"
            id="message-thread-empty"
          >
            {gettext("No messages yet. Say hello.")}
          </li>
          <li
            :for={{dom_id, message} <- @streams.messages}
            id={dom_id}
            class={[
              "message-row flex",
              (mine?(message, @current_scope) && "justify-end") || "justify-start"
            ]}
          >
            <div class={[
              "message-bubble max-w-[80%] rounded-2xl px-3 py-2",
              (mine?(message, @current_scope) && "bg-primary text-primary-content") ||
                "bg-base-200"
            ]}>
              <p class="message-body break-words whitespace-pre-wrap">{message.body}</p>
              <p class="message-time text-xs opacity-60">
                {format_datetime(message.inserted_at)}
              </p>
            </div>
          </li>
        </ol>

        <.form
          for={@compose_form}
          id="message-compose-form"
          phx-submit="send"
          class="mt-4 flex items-end gap-2"
        >
          <div class="flex-1">
            <.input
              field={@compose_form[:body]}
              type="textarea"
              label={gettext("Message")}
              maxlength={Message.max_body()}
              rows="2"
            />
          </div>
          <.button
            type="submit"
            id="message-send"
            class="btn btn-primary"
            phx-disable-with={gettext("Sending…")}
          >
            {gettext("Send")}
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  defp mine?(%Message{sender_id: sender_id}, current_scope),
    do: sender_id == current_scope.user.id
end
