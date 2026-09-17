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

  # Each POST is bounded per read, not end to end: an endpoint that dribbles its response slowly
  # enough could hold a `:default` slot — the queue that carries medication reminders —
  # indefinitely. A hard job deadline caps the whole fan-out.
  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(60)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"notification_id" => notification_id}}) do
    Goodmao2.Notifications.dispatch_web_push(notification_id)
  end
end
