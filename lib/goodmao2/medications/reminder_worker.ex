defmodule Goodmao2.Medications.ReminderWorker do
  @moduledoc """
  Oban cron worker for medication scheduling (ADR-0019).

  Each run keeps the rolling dose horizon filled, ages overdue slots to `missed`, and sends a
  one-time `medication_due` reminder (bell + Web Push) for slots that have come due. The real work
  lives in `Goodmao2.Medications` so it is testable without Oban; this worker is a thin shell.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Goodmao2.Medications

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Medications.materialize_due_doses()
    Medications.mark_missed_doses()
    Medications.dispatch_due_reminders()
    :ok
  end
end
