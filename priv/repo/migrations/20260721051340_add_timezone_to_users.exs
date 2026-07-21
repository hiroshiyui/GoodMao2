defmodule Goodmao2.Repo.Migrations.AddTimezoneToUsers do
  use Ecto.Migration

  def change do
    # Preferred IANA timezone for display/entry (ADR-0018). Nullable — nil means "use the admin
    # system default, then Etc/UTC". Validated in the app against the live tz database.
    alter table(:users) do
      add :timezone, :string
    end
  end
end
