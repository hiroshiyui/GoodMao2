defmodule Goodmao2.Repo.Migrations.AddTimelinePageSizeToUsers do
  use Ecto.Migration

  def change do
    # Persisted per-user timeline "per page" preference (roadmap §8). Non-null with a default so
    # every existing and new row has a sane value; the app whitelists it to 25/50/100.
    alter table(:users) do
      add :timeline_page_size, :integer, null: false, default: 25
    end
  end
end
