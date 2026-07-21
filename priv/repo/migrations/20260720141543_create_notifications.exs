defmodule Goodmao2.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      # The recipient. A notification is a per-user event row; deleting the user
      # takes their notifications with them.
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # The discriminator: access_granted | access_revoked | log_added | announcement.
      # The display sentence is rendered from `type` + `payload` at read time (never
      # stored as a string), so it stays localizable in every locale.
      add :type, :string, null: false

      # Denormalized snapshot of what's needed to render the copy and link the target:
      # pet id/name, actor handle/display, role, log type + entry id, announcement
      # title/body. Snapshotted at event time, so later renames don't rewrite history.
      add :payload, :map, null: false, default: %{}

      # Null = unread. Drives the bell badge and the read filter.
      add :read_at, :utc_datetime

      # Soft-delete marker (ADR-0008). Null = live; reads filter `deleted_at IS NULL`.
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # The feed query: a user's live notifications, newest first.
    create index(:notifications, [:user_id, :inserted_at])

    # The unread-count badge: only live, unread rows for a user.
    create index(:notifications, [:user_id],
             where: "read_at IS NULL AND deleted_at IS NULL",
             name: :notifications_unread_index
           )
  end
end
