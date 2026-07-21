defmodule Goodmao2.Messaging.MessagePushWorker do
  @moduledoc """
  Delivers a new mailbox message to the recipient's browsers as Web Push (ADR-0011 Stage 2).

  A thin shell over `Goodmao2.Messaging.dispatch_message_push/1` — the real logic (resolve the
  other participant, render the payload, send to their live subscriptions via
  `Goodmao2.Notifications.push_to_user/2`) lives in the context. Enqueued from
  `Messaging.send_message/3`, only when VAPID is configured. Mailbox messages write no bell
  row, so this is their sole push path.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    Goodmao2.Messaging.dispatch_message_push(message_id)
  end
end
