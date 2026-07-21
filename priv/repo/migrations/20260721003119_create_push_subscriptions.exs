defmodule Goodmao2.Repo.Migrations.CreatePushSubscriptions do
  use Ecto.Migration

  def change do
    # A browser push endpoint a user opted into (ADR-0011 Stage 2, Web Push). One row per
    # device/endpoint; deleting the user takes their subscriptions with them.
    create table(:push_subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      # The push-service URL the browser handed us. Browser-supplied, so it is an SSRF
      # vector — validated (HTTPS + public-resolving) before it is ever stored.
      add :endpoint, :text, null: false

      # The subscriber's raw ECDH public key (65 bytes) and auth secret (16 bytes), used
      # for RFC 8291 payload encryption. Stored as raw binary, not base64.
      add :p256dh, :binary, null: false
      add :auth, :binary, null: false

      # Diagnostic only — which browser registered this endpoint.
      add :user_agent, :string

      # Soft-delete marker (ADR-0008). Null = live; reads filter `deleted_at IS NULL`.
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # An endpoint is globally unique (the push service issues one per device); a second
    # user claiming the same endpoint is a conflict, not a duplicate.
    create unique_index(:push_subscriptions, [:endpoint])
    create index(:push_subscriptions, [:user_id])
  end
end
