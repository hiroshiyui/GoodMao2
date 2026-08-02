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

  @doc """
  Grants `grantee` a role on `pet`, then back-dates it so the grant has **expired**.

  Expiry is enforced by `Pets.effective_access/2`, which every downstream context and
  LiveView trusts transitively — so this exists to let each of them prove it denies, rather
  than that being verified once at `Pets.can?` and assumed everywhere else. The update is
  written directly because `grant_access/3` rejects a past `expires_at` (validly — a grant
  that expires before it is made is a user error, not a test fixture).
  """
  def expired_grant_fixture(pet, granter, grantee, role \\ "co_caretaker") do
    past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

    grant_fixture(pet, granter, grantee, role)
    |> Ecto.Changeset.change(expires_at: past)
    |> Goodmao2.Repo.update!()
  end

  @doc """
  Grants `grantee` a role on `pet`, then revokes it through the real `Pets.revoke_access/3`.

  The revoked grant row stays in the table — revocation is a status transition, not a
  delete — so it remains available to any query that forgets to filter on `status`.
  """
  def revoked_grant_fixture(pet, granter, grantee, role \\ "co_caretaker") do
    access = grant_fixture(pet, granter, grantee, role)
    {:ok, revoked} = Pets.revoke_access(granter, pet, access)
    revoked
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
