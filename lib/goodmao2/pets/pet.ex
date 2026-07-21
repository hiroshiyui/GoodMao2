defmodule Goodmao2.Pets.Pet do
  @moduledoc """
  A pet — the subject of the health timeline.

  Ownership is **not** a column here: it is modeled as `PetAccess` rows with the
  `owner` role, so a household can have several equal co-owners. `created_by_user_id`
  is an audit reference only (no navigation).

  End-of-care is a lifecycle status transition (`lifecycle_status`), never a
  deletion — the record and its timeline are preserved.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @species ~w(cat dog rabbit bird hamster reptile fish other)
  @sexes ~w(unknown male female)
  @weight_units ~w(grams kilograms pounds)
  @lifecycle_statuses ~w(active passed_away rehomed lost other)

  def species, do: @species
  def sexes, do: @sexes
  def weight_units, do: @weight_units
  def lifecycle_statuses, do: @lifecycle_statuses

  schema "pets" do
    field :created_by_user_id, :id

    field :name, :string
    field :species, :string, default: "cat"
    field :breed, :string
    field :color, :string
    field :sex, :string, default: "unknown"
    field :birth_date, :date
    field :neutered, :boolean, default: false
    field :photo_url, :string
    field :weight_unit, :string, default: "grams"

    field :lifecycle_status, :string, default: "active"
    field :ended_at, :utc_datetime
    field :history_hidden, :boolean, default: false

    has_many :accesses, Goodmao2.Pets.PetAccess
    has_many :log_entries, Goodmao2.Logs.LogEntry

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or editing a pet's descriptive attributes.

  Lifecycle transitions are handled separately by `lifecycle_changeset/2` so the
  everyday edit form can never accidentally end a pet's care.
  """
  def changeset(pet, attrs) do
    pet
    |> cast(attrs, [
      :name,
      :species,
      :breed,
      :color,
      :sex,
      :birth_date,
      :neutered,
      :photo_url,
      :weight_unit,
      :history_hidden
    ])
    |> validate_required([:name, :species, :sex, :weight_unit])
    |> validate_length(:name, min: 1, max: 100)
    |> validate_length(:breed, max: 100)
    |> validate_length(:color, max: 100)
    |> validate_inclusion(:species, @species)
    |> validate_inclusion(:sex, @sexes)
    |> validate_inclusion(:weight_unit, @weight_units)
    |> validate_birth_date_not_future()
  end

  @doc """
  Changeset for an owner-only lifecycle transition (end-of-care).

  Moving out of `active` stamps `ended_at` (backdatable to the given value or now);
  returning to `active` clears it.
  """
  def lifecycle_changeset(pet, attrs) do
    pet
    |> cast(attrs, [:lifecycle_status, :ended_at])
    |> validate_required([:lifecycle_status])
    |> validate_inclusion(:lifecycle_status, @lifecycle_statuses)
    |> put_ended_at()
    |> validate_ended_at_not_future()
  end

  defp put_ended_at(changeset) do
    status = get_field(changeset, :lifecycle_status)

    cond do
      status == "active" ->
        put_change(changeset, :ended_at, nil)

      get_field(changeset, :ended_at) == nil ->
        put_change(changeset, :ended_at, DateTime.utc_now() |> DateTime.truncate(:second))

      true ->
        changeset
    end
  end

  defp validate_birth_date_not_future(changeset) do
    case get_change(changeset, :birth_date) do
      %Date{} = date ->
        if Date.after?(date, Date.utc_today()) do
          add_error(changeset, :birth_date, "cannot be in the future")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_ended_at_not_future(changeset) do
    case get_field(changeset, :ended_at) do
      %DateTime{} = dt ->
        if DateTime.after?(dt, DateTime.utc_now()) do
          add_error(changeset, :ended_at, "cannot be in the future")
        else
          changeset
        end

      _ ->
        changeset
    end
  end
end
