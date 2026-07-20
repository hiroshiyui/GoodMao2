defmodule Goodmao2.Repo.Migrations.CreateVetProfiles do
  use Ecto.Migration

  def change do
    create table(:vet_profiles) do
      # One profile per user; the vet per-pet role requires a *verified* one of these.
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :license_number, :string, null: false
      add :licensing_body, :string, null: false
      add :region, :string, null: false
      add :clinic_name, :string, null: false
      add :specialty, :string

      # pending | verified | rejected
      add :verification_status, :string, null: false, default: "pending"
      add :verified_at, :utc_datetime

      # Audit only, no schema navigation — which administrator reviewed it.
      add :verified_by_admin_id, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    # 0..1 profile per user.
    create unique_index(:vet_profiles, [:user_id])
    # The admin review queue filters pending profiles.
    create index(:vet_profiles, [:verification_status])
  end
end
