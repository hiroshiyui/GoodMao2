defmodule Goodmao2.PetsFixtures do
  @moduledoc """
  Test helpers for creating pets, access grants, and log entries.
  """
  alias Goodmao2.{Logs, Pets}

  def valid_pet_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "name" => "Mittens",
      "species" => "cat",
      "sex" => "female",
      "weight_unit" => "grams"
    })
  end

  @doc "Creates a pet owned by `owner` (an `%Accounts.User{}`)."
  def pet_fixture(owner, attrs \\ %{}) do
    {:ok, pet} = Pets.create_pet(owner, valid_pet_attributes(attrs))
    pet
  end

  @doc """
  Grants `grantee` a role on `pet`, performed by `granter` (defaults to an owner).

  The `vet` role requires a verified `VetProfile`, so one is provisioned for the grantee.
  """
  def grant_fixture(pet, granter, grantee, role \\ "co_caretaker") do
    if role == "vet", do: Goodmao2.AccountsFixtures.verified_vet_profile_fixture(grantee)

    {:ok, access} =
      Pets.grant_access(granter, pet, %{"identifier" => grantee.email, "role" => role})

    access
  end

  @doc "Creates a log entry on `pet` recorded by `user`."
  def log_entry_fixture(user, pet, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        "type" => "food",
        "data" => %{"amount" => "full"}
      })

    {:ok, entry} = Logs.create_entry(user, pet, attrs)
    entry
  end
end
