defmodule Goodmao2.Repo.Migrations.EnforceSingleAdmin do
  use Ecto.Migration

  # At most one administrator (ADR-0016). The `is_admin: true` flag is set only for the
  # first registered account, computed as `not Repo.exists?(User)` — but that read and the
  # insert are not one atomic step, so two concurrent first registrations can both see an
  # empty table and both become admin. A partial unique index over the single is_admin=true
  # row is the real guard: the loser's insert fails the constraint, and `register_user`
  # retries it as an ordinary account.
  def change do
    create unique_index(:users, [:is_admin],
             where: "is_admin",
             name: :users_single_admin_index
           )
  end
end
