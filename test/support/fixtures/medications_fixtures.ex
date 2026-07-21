defmodule Goodmao2.MedicationsFixtures do
  @moduledoc "Test fixtures for the Medications context (ADR-0019)."

  alias Goodmao2.Medications

  def valid_schedule_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "medication_name" => "Amoxicillin",
      "dose" => "50mg",
      "times_of_day" => [~T[08:00:00], ~T[20:00:00]],
      "interval_days" => 1,
      "start_date" => Date.utc_today(),
      "timezone" => "Asia/Taipei"
    })
  end

  @doc "Creates a schedule on `pet`, authored by `user` (who must hold `:write`)."
  def medication_schedule_fixture(user, pet, attrs \\ %{}) do
    {:ok, schedule} = Medications.create_schedule(user, pet, valid_schedule_attributes(attrs))
    schedule
  end
end
