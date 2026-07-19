defmodule Goodmao2.Logs.LogEntryRevision do
  @moduledoc """
  An immutable snapshot of a `LogEntry` as it stood *before* an edit (ADR-0009).

  Each real edit writes one row: a `jsonb` `snapshot` of the prior `type` + `data` +
  `note` + `occurred_at` + `visibility` (never the share token), plus who edited and when,
  and a denormalized `pet_id` for scoping. Revisions are never edited or deleted; they ride
  the parent entry's soft-delete, so the audit trail stays intact.
  """
  use Ecto.Schema

  schema "log_entry_revisions" do
    # Denormalized scope + audit ref, plain ids without navigations (repo convention).
    field :pet_id, :id
    field :edited_by_user_id, :id
    field :snapshot, :map, default: %{}

    belongs_to :log_entry, Goodmao2.Logs.LogEntry

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
