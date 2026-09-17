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

  # Each POST is bounded per read, not end to end: an endpoint that dribbles its response slowly
  # enough could hold a `:default` slot — the queue that carries medication reminders —
  # indefinitely. A hard job deadline caps the whole fan-out.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => message_id}}) do
    Goodmao2.Messaging.dispatch_message_push(message_id)
  end
end
