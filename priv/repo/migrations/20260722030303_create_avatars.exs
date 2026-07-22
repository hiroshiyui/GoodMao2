defmodule Goodmao2.Repo.Migrations.CreateAvatars do
  use Ecto.Migration

  def change do
    create table(:avatars) do
      # Polymorphic owner: exactly one avatar per (owner_type, owner_id). No FK navigation —
      # owner_type spans two tables (users, pets) and the id is only ever resolved by the
      # owning context, matching the repo's audit-only id-column convention.
      add :owner_type, :string, null: false
      add :owner_id, :bigint, null: false
      add :status, :string, null: false, default: "processing"
      add :content_type, :string
      add :byte_size, :bigint
      add :uploaded_by_user_id, :bigint

      timestamps(type: :utc_datetime)
    end

    create constraint(:avatars, :avatars_owner_type_must_be_known,
             check: "owner_type in ('user', 'pet')"
           )

    # One current avatar per owner — the upsert target for `Media.Avatars.set_avatar/4`.
    create unique_index(:avatars, [:owner_type, :owner_id])
  end
end
