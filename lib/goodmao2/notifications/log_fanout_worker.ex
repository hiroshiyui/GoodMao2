defmodule Goodmao2.Notifications.LogFanoutWorker do
  @moduledoc """
  Fans a new log entry out to the pet's other effective followers as `log_added`
  notifications.

  A thin shell over `Goodmao2.Notifications.fan_out_log_added/2` — the real logic
  (recipient resolution + per-entry visibility filtering) lives in the context so it stays
  testable without Oban. Enqueued from `Goodmao2.Logs.create_entry/3`.

  Fan-out is unbatched and at-least-once (an Oban retry mid-run may double-post a row);
  acceptable for a best-effort feed per ADR-0011.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pet_id" => pet_id, "entry_id" => entry_id}}) do
    Goodmao2.Notifications.fan_out_log_added(pet_id, entry_id)
  end
end
