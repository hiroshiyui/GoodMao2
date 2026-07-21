defmodule Goodmao2.Notifications.Notification do
  @moduledoc """
  A single in-site notification for one recipient (the "bell" feed).

  Like `Goodmao2.Logs.LogEntry`, one table holds every kind of event; `type` is the
  discriminator and a `jsonb` `payload` carries the denormalized facts needed to render
  the copy and link the target. The **display sentence is never stored** — it is rendered
  from `type` + `payload` through Gettext at read time (see
  `Goodmao2Web.Helpers.notification_summary/1`), so it stays localizable in every locale.

  Per-type `payload` validation lives in `changeset/2`. Notifications are soft-deleted via
  `deleted_at`; `read_at` (null = unread) drives the unread badge.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(access_granted access_revoked log_added announcement medication_due)

  def types, do: @types

  schema "notifications" do
    belongs_to :user, Goodmao2.Accounts.User

    field :type, :string
    field :payload, :map, default: %{}
    field :read_at, :utc_datetime
    field :deleted_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a notification.

  Validates the recipient and type, then dispatches to a per-type check that the
  `payload` carries the keys that type's copy renderer needs.
  """
  def create_changeset(notification, attrs) do
    notification
    |> cast(attrs, [:user_id, :type, :payload])
    |> validate_required([:user_id, :type])
    |> validate_inclusion(:type, @types)
    |> validate_payload()
    |> foreign_key_constraint(:user_id)
  end

  # Each type names the payload keys its renderer relies on. Missing keys would render a
  # broken sentence, so require them here where the row is created.
  @required_payload %{
    "access_granted" => ~w(pet_id pet_name role),
    "access_revoked" => ~w(pet_id pet_name),
    "log_added" => ~w(pet_id pet_name entry_id log_type),
    "announcement" => ~w(title body),
    "medication_due" => ~w(pet_id pet_name medication_name dose)
  }

  defp validate_payload(changeset) do
    type = get_field(changeset, :type)
    payload = get_field(changeset, :payload) || %{}
    required = Map.get(@required_payload, type, [])

    missing = Enum.reject(required, &Map.has_key?(payload, &1))

    if missing == [] do
      changeset
    else
      add_error(changeset, :payload, "is missing keys: #{Enum.join(missing, ", ")}")
    end
  end
end
