defmodule Goodmao2.Accounts.VetProfile do
  @moduledoc """
  A veterinarian's account-level credential — the proof of professional status.

  There is at most **one** profile per user. The per-pet `vet` role requires a profile
  whose `verification_status` is `"verified"` (enforced in `Goodmao2.Pets.grant_access/3`),
  so "vet" input carries authority rather than being anonymous advice.

  An administrator reviews a submitted profile; `verified_by_admin_id` is an audit reference
  (no schema navigation, matching the project's other audit refs).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending verified rejected)

  def statuses, do: @statuses

  schema "vet_profiles" do
    field :license_number, :string
    field :licensing_body, :string
    field :region, :string
    field :clinic_name, :string
    field :specialty, :string

    field :verification_status, :string, default: "pending"
    field :verified_at, :utc_datetime
    field :verified_by_admin_id, :id

    belongs_to :user, Goodmao2.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for the applicant submitting or re-submitting their credentials.

  A (re)submission always returns the profile to `pending` review and clears any prior
  verdict — an edited credential must be re-checked.
  """
  def submit_changeset(profile, attrs) do
    profile
    |> cast(attrs, [:license_number, :licensing_body, :region, :clinic_name, :specialty])
    |> validate_required([:license_number, :licensing_body, :region, :clinic_name])
    |> validate_length(:license_number, max: 100)
    |> validate_length(:licensing_body, max: 160)
    |> validate_length(:region, max: 160)
    |> validate_length(:clinic_name, max: 160)
    |> validate_length(:specialty, max: 160)
    |> put_change(:verification_status, "pending")
    |> put_change(:verified_at, nil)
    |> put_change(:verified_by_admin_id, nil)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for an administrator's verdict — sets the status and stamps the reviewer.
  """
  def review_changeset(profile, status, admin_id) when status in @statuses do
    verified_at = if status == "verified", do: DateTime.utc_now() |> DateTime.truncate(:second)

    profile
    |> change(%{
      verification_status: status,
      verified_at: verified_at,
      verified_by_admin_id: admin_id
    })
  end
end
