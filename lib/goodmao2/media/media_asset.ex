defmodule Goodmao2.Media.MediaAsset do
  @moduledoc """
  A purified, opaque media object attached to a `life` log entry (ADR-0005).

  The row is metadata only: the physical storage path is **derived from the `id` and never
  stored**, so serving is path-traversal-proof by construction. `pet_id` is the denormalized
  authorization anchor — serving resolves an asset by its own id and re-applies that pet's
  read authorization. Soft-deleted via `deleted_at`, riding the parent log's lifecycle.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(image video)

  schema "media_assets" do
    field :pet_id, :id
    field :uploaded_by_user_id, :id
    field :kind, :string
    field :content_type, :string
    field :byte_size, :integer
    field :caption, :string
    field :deleted_at, :utc_datetime

    belongs_to :log_entry, Goodmao2.Logs.LogEntry

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(asset, attrs) do
    asset
    |> cast(attrs, [
      :log_entry_id,
      :pet_id,
      :uploaded_by_user_id,
      :kind,
      :content_type,
      :byte_size,
      :caption
    ])
    |> validate_required([:log_entry_id, :pet_id, :kind, :content_type, :byte_size])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:caption, max: 500)
  end
end
