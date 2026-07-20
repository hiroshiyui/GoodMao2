defmodule Goodmao2.Repo.Migrations.CreateHealthSummaryReports do
  use Ecto.Migration

  def change do
    create table(:health_summary_reports) do
      add :pet_id, references(:pets, on_delete: :delete_all), null: false

      # The inclusive occurred_at window the report covers.
      add :period_start, :utc_datetime, null: false
      add :period_end, :utc_datetime, null: false

      # Audit only, no schema navigation — who generated the snapshot.
      add :generated_by_user_id, references(:users, on_delete: :nilify_all)

      # The frozen point-in-time snapshot (rollups + weight series + shareable entries).
      # Private entries are never included, so the snapshot is safe to share.
      add :content, :map, null: false

      # Optional expiring anonymous share link: only the SHA-256 hash of the token is
      # stored (the raw token is shown once at creation), always paired with an expiry.
      add :share_token_hash, :binary
      add :share_expires_at, :utc_datetime

      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:health_summary_reports, [:pet_id])
    # Anonymous token lookup matches on the hash; unique so a token maps to one report.
    create unique_index(:health_summary_reports, [:share_token_hash])
  end
end
