defmodule Goodmao2.Notifications.PushDispatchWorker do
  @moduledoc """
  Delivers one notification to its recipient's browsers as Web Push (ADR-0011 Stage 2).

  A thin shell over `Goodmao2.Notifications.dispatch_web_push/1` — the real logic (load the
  row, its live subscriptions, encrypt + POST to each) lives in the context so it stays
  testable without Oban. Enqueued from `Goodmao2.Notifications.create/3` (the single choke
  point every bell row passes through), only when VAPID is configured.

  Delivery is best-effort: a stale subscription is pruned on 410, other failures are logged.
  A job that finds no live subscriptions (the user never opted in) is a no-op success.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"notification_id" => notification_id}}) do
    Goodmao2.Notifications.dispatch_web_push(notification_id)
  end
end
