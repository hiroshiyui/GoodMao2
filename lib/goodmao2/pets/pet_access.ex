defmodule Goodmao2.Pets.PetAccess do
  @moduledoc """
  A follower / permission grant — the authorization core.

  One row per `(pet, user)` relationship. `owner` means full control; a pet must
  always retain at least one *effective* owner grant (enforced in the `Pets`
  context, not here).

  **Effective access** = `status == "active"` AND (`expires_at` is nil OR in the
  future). Time-boxed grants (`expires_at` set) are typical for vets.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles ~w(owner co_caretaker viewer vet)
  @statuses ~w(active revoked)

  def roles, do: @roles
  def statuses, do: @statuses

  schema "pet_accesses" do
    field :role, :string
    field :granted_by_user_id, :id
    field :granted_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :status, :string, default: "active"

    belongs_to :pet, Goodmao2.Pets.Pet
    belongs_to :user, Goodmao2.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an access grant.
  """
  def changeset(access, attrs) do
    access
    |> cast(attrs, [
      :pet_id,
      :user_id,
      :role,
      :granted_by_user_id,
      :granted_at,
      :expires_at,
      :status
    ])
    |> validate_required([:pet_id, :user_id, :role, :status])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:status, @statuses)
    |> put_granted_at()
    |> validate_expires_in_future()
    |> unique_constraint([:pet_id, :user_id],
      name: :pet_accesses_pet_id_user_id_index,
      message: "already has a grant for this pet"
    )
    |> foreign_key_constraint(:pet_id)
    |> foreign_key_constraint(:user_id)
  end

  defp put_granted_at(changeset) do
    if get_field(changeset, :granted_at) do
      changeset
    else
      put_change(changeset, :granted_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end

  defp validate_expires_in_future(changeset) do
    case get_change(changeset, :expires_at) do
      %DateTime{} = dt ->
        if DateTime.after?(dt, DateTime.utc_now()) do
          changeset
        else
          add_error(changeset, :expires_at, "must be in the future")
        end

      _ ->
        changeset
    end
  end
end
