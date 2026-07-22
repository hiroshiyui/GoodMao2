defmodule Goodmao2.Media.Avatar do
  @moduledoc """
  A purified profile image for a user or a pet (ADR-0020).

  Polymorphic by `(owner_type, owner_id)` — exactly one avatar per owner (a unique index) —
  so both surfaces share one pipeline. The row is metadata only: the physical storage path is
  **derived from the owner key and never stored**, so serving is path-traversal-proof by
  construction. Avatars are **images only**; `status` tracks the async purify lifecycle
  (`processing` → `ready`/`failed`), and `updated_at` doubles as the cache-busting version.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @owner_types ~w(user pet)
  @statuses ~w(processing ready failed)

  schema "avatars" do
    field :owner_type, :string
    field :owner_id, :id
    field :status, :string, default: "processing"
    field :content_type, :string
    field :byte_size, :integer
    field :uploaded_by_user_id, :id

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for (re)claiming an owner's avatar slot as `processing` before purification."
  def upsert_changeset(avatar, attrs) do
    avatar
    |> cast(attrs, [:owner_type, :owner_id, :status, :uploaded_by_user_id])
    |> validate_required([:owner_type, :owner_id, :status])
    |> validate_inclusion(:owner_type, @owner_types)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:owner_type, :owner_id])
  end

  @doc "Changeset marking an avatar `ready` with the purified object's metadata."
  def ready_changeset(avatar, attrs) do
    avatar
    |> cast(attrs, [:status, :content_type, :byte_size])
    |> put_change(:status, "ready")
    |> validate_required([:content_type, :byte_size])
  end
end
