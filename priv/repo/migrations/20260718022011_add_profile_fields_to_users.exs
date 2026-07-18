defmodule Goodmao2.Repo.Migrations.AddProfileFieldsToUsers do
  use Ecto.Migration

  def change do
    # The citext extension is already enabled by the auth-tables migration.
    alter table(:users) do
      # Public @handle used to mention/invite the user. Stored lowercase-canonical,
      # unique case-insensitively via the citext type.
      add :handle, :citext
      # Free-text name shown in the UI, distinct from the email and the handle.
      add :display_name, :string
      # The sole global role. The first registered account becomes the administrator;
      # this is NOT a per-pet role and grants no backdoor to pet data.
      add :is_admin, :boolean, default: false, null: false
    end

    create unique_index(:users, [:handle])
  end
end
