defmodule Goodmao2.Reports.HealthSummaryReport do
  @moduledoc """
  A generated, point-in-time health summary for a pet over a date range.

  The `content` is a **frozen snapshot** computed at generation time (rollups + weight
  series + the entries a non-owner grant may see), so the report stays faithful to its
  moment even after the timeline changes or the reader's live access expires. **Private
  entries are never included**, so the snapshot is safe to hand to a vet — including via the
  optional anonymous share link.

  The share link stores only the SHA-256 **hash** of its token and is always paired with an
  expiry (`share_expires_at`); the raw token is shown once at creation. Soft-deleted via
  `deleted_at`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "health_summary_reports" do
    field :pet_id, :id
    field :generated_by_user_id, :id
    field :period_start, :utc_datetime
    field :period_end, :utc_datetime
    field :content, :map

    field :share_token_hash, :binary
    field :share_expires_at, :utc_datetime

    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating a report from a pre-built snapshot."
  def create_changeset(report, attrs) do
    report
    |> cast(attrs, [:pet_id, :generated_by_user_id, :period_start, :period_end, :content])
    |> validate_required([:pet_id, :period_start, :period_end, :content])
    |> validate_period()
    |> foreign_key_constraint(:pet_id)
  end

  defp validate_period(changeset) do
    start = get_field(changeset, :period_start)
    stop = get_field(changeset, :period_end)

    if start && stop && DateTime.after?(start, stop) do
      add_error(changeset, :period_end, "must be on or after the start date")
    else
      changeset
    end
  end
end
