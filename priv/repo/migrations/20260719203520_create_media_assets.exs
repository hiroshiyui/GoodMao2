defmodule Goodmao2.Repo.Migrations.CreateMediaAssets do
  use Ecto.Migration

  def change do
    create table(:media_assets) do
      # The life log this media belongs to. Cascade so media never outlives its entry row.
      add :log_entry_id, references(:log_entries, on_delete: :delete_all), null: false

      # Denormalized authorization anchor (ADR-0005): serving resolves the asset by its own
      # id and re-applies *this pet's* read authorization. There is no pet_id in the URL.
      add :pet_id, references(:pets, on_delete: :delete_all), null: false

      # Who uploaded it — audit only, no schema navigation.
      add :uploaded_by_user_id, references(:users, on_delete: :nilify_all)

      # "image" | "video", and the server-validated (magic-byte) content type. The physical
      # path is derived from the id and never stored, so it is path-traversal-proof.
      add :kind, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :bigint, null: false
      add :caption, :string

      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:media_assets, [:log_entry_id])
    create index(:media_assets, [:pet_id])
  end
end
