defmodule Goodmao2.Repo.Migrations.RetireUnboundPushSubscriptions do
  use Ecto.Migration

  # Subscriptions registered before `session_token_hash` existed name no session, so revoking a
  # session (log-out, a password change elsewhere) can never release them: a lost or shared
  # device would keep receiving its last user's pushes. Retire them (soft-delete, ADR-0008).
  # The settings page then finds no live subscription for the browser, drops its copy, and
  # offers "Enable push" again; re-enabling registers the endpoint under the current session.
  def up do
    execute("""
    UPDATE push_subscriptions
    SET deleted_at = date_trunc('second', now() AT TIME ZONE 'UTC'),
        updated_at = date_trunc('second', now() AT TIME ZONE 'UTC')
    WHERE session_token_hash IS NULL AND deleted_at IS NULL
    """)
  end

  # Which rows this retired is not recorded, and reviving them would reopen the gap.
  def down, do: :ok
end
