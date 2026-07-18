defmodule Goodmao2.Repo.Migrations.CreatePetAccesses do
  use Ecto.Migration

  def change do
    create table(:pet_accesses) do
      add :pet_id, references(:pets, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # owner | co_caretaker | viewer | vet. A pet must always retain >= 1 effective
      # owner grant (enforced in the application layer).
      add :role, :string, null: false

      # Audit only, no FK — who granted this access.
      add :granted_by_user_id, references(:users, on_delete: :nilify_all)
      add :granted_at, :utc_datetime, null: false

      # null = permanent; set = time-boxed (typical for vet grants).
      add :expires_at, :utc_datetime

      # active | revoked
      add :status, :string, null: false, default: "active"

      timestamps(type: :utc_datetime)
    end

    # One relationship row per (pet, user).
    create unique_index(:pet_accesses, [:pet_id, :user_id])
    create index(:pet_accesses, [:user_id])
    # The effective-access claim predicate filters on status/expiry per pet.
    create index(:pet_accesses, [:pet_id, :status])
  end
end
