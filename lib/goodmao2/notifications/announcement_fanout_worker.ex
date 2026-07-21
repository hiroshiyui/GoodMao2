defmodule Goodmao2.Notifications.AnnouncementFanoutWorker do
  @moduledoc """
  Fans an administrator announcement out to every user as an `announcement` notification.

  A thin shell over `Goodmao2.Notifications.fan_out_announcement/1` — enqueued by
  `Goodmao2.Notifications.broadcast_announcement/2` (admin-gated). Fan-out is unbatched and
  at-least-once per ADR-0011.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"title" => _, "body" => _} = args}) do
    Goodmao2.Notifications.fan_out_announcement(args)
  end
end
