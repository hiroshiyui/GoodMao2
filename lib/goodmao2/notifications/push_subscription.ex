defmodule Goodmao2.Notifications.PushSubscription do
  @moduledoc """
  A browser Web Push subscription for one user (ADR-0011 Stage 2).

  Each row is a push-service endpoint the browser handed us, plus the subscriber's ECDH
  public key (`p256dh`, 65 bytes) and auth secret (`auth`, 16 bytes) — the inputs to
  RFC 8291 payload encryption. Endpoints are globally unique (the push service issues one
  per device). Soft-deleted via `deleted_at` (ADR-0008).

  The `endpoint` is **browser-supplied**, so it is an SSRF vector: the changeset rejects
  anything that is not HTTPS and does not resolve to a public address
  (`Goodmao2.Notifications.WebPush.SafeClient.validate_url/1`) before it can be stored.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Goodmao2.Notifications.WebPush.SafeClient

  schema "push_subscriptions" do
    belongs_to :user, Goodmao2.Accounts.User

    field :endpoint, :string
    field :p256dh, :binary
    field :auth, :binary
    field :user_agent, :string
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :user_agent, :user_id])
    |> validate_required([:endpoint, :p256dh, :auth, :user_id])
    |> validate_length(:endpoint, max: 2048)
    |> validate_endpoint_url()
    |> unique_constraint(:endpoint)
    |> foreign_key_constraint(:user_id)
  end

  # SSRF guard at storage time: only a public HTTPS endpoint may be persisted, so a stored
  # subscription can never later steer an outbound push at a private/loopback address.
  defp validate_endpoint_url(changeset) do
    validate_change(changeset, :endpoint, fn :endpoint, endpoint ->
      with %URI{scheme: "https", host: host} when is_binary(host) and host != "" <-
             URI.parse(endpoint),
           :ok <- SafeClient.validate_url(endpoint) do
        []
      else
        {:error, _reason} -> [endpoint: "must resolve to a public HTTPS endpoint"]
        _ -> [endpoint: "must be a valid HTTPS URL"]
      end
    end)
  end
end
