defmodule Goodmao2.Repo.Migrations.CreatePets do
  use Ecto.Migration

  def change do
    create table(:pets) do
      # Who created the pet — audit only, no FK. Ownership is modeled as PetAccess
      # rows with role "owner", never a column on the pet.
      add :created_by_user_id, references(:users, on_delete: :nilify_all)

      add :name, :string, null: false
      add :species, :string, null: false, default: "cat"
      add :breed, :string
      add :color, :string
      add :sex, :string, null: false, default: "unknown"
      add :birth_date, :date
      add :neutered, :boolean, default: false, null: false
      add :photo_url, :string
      add :weight_unit, :string, null: false, default: "grams"

      # End-of-care is a lifecycle status transition, not a deletion — the record
      # and its timeline are preserved. `ended_at` timestamps the exit from active.
      add :lifecycle_status, :string, null: false, default: "active"
      add :ended_at, :utc_datetime

      # Owner opt-in: when true the pet's log views are existence-hidden (404).
      # Independent of lifecycle_status and reversible.
      add :history_hidden, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:pets, [:created_by_user_id])
  end
end
