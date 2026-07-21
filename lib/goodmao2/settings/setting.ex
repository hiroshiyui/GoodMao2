defmodule Goodmao2.Settings.Setting do
  @moduledoc """
  A single global key/value system setting (see `Goodmao2.Settings`).

  Values are opaque strings. A secret value is encrypted by the writer before it is stored
  (e.g. the VAPID private key via `Goodmao2.Notifications.WebPush.VapidVault`) — this schema
  makes no confidentiality promise of its own.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field :key, :string
    field :value, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end
end
