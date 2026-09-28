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

  # The uploader's description of the photo/video — the image's `alt` text (`Helpers.media_alt/1`).
  # Bounded by the column (`:string` → varchar(255)), counted in codepoints as Postgres counts
  # them: the old 500-grapheme bound let a 256–500-character caption past the changeset only to
  # fail the insert, in the purify worker, three times over.
  @caption_max_length 255

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
    |> validate_caption()
  end

  @doc """
  Changes only an existing asset's description (`Media.update_media_caption/5`). Nothing else is
  castable, so this path cannot move an asset between entries or rewrite its metadata.
  """
  def caption_changeset(asset, attrs) do
    asset
    |> cast(attrs, [:caption])
    |> validate_caption()
  end

  @doc "The longest a description may be, in codepoints."
  def caption_max_length, do: @caption_max_length

  @doc """
  Normalizes an uploader-supplied description for the upload path: trimmed, blank → `nil`, and
  cut to `caption_max_length/0`. `nil` (not `""`) matters at render time — `alt=""` would declare
  a chosen photo decorative, while `nil` falls back to a localized description.
  """
  def normalize_caption(caption) when is_binary(caption) do
    case String.trim(caption) do
      "" -> nil
      trimmed -> trimmed |> String.codepoints() |> Enum.take(@caption_max_length) |> Enum.join()
    end
  end

  def normalize_caption(_), do: nil

  defp validate_caption(changeset) do
    changeset
    |> update_change(:caption, fn
      caption when is_binary(caption) ->
        case String.trim(caption) do
          "" -> nil
          trimmed -> trimmed
        end

      other ->
        other
    end)
    |> validate_length(:caption, max: @caption_max_length, count: :codepoints)
  end
end
