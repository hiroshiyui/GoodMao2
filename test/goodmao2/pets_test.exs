defmodule Goodmao2.PetsTest do
  use Goodmao2.DataCase, async: true

  alias Goodmao2.Pets
  alias Goodmao2.Pets.PetAccess

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  describe "create_pet/2" do
    test "creates the pet and an owner grant for the creator in one transaction" do
      owner = user_fixture()
      assert {:ok, pet} = Pets.create_pet(owner, valid_pet_attributes())
      assert pet.name == "Mittens"
      assert pet.created_by_user_id == owner.id
      assert Pets.effective_role(pet, owner) == "owner"
    end

    test "rejects invalid attributes" do
      owner = user_fixture()
      assert {:error, changeset} = Pets.create_pet(owner, %{"name" => ""})
      assert %{name: _} = errors_on(changeset)
    end

    test "accepts the broadened species set (roadmap §8)" do
      owner = user_fixture()

      for species <- ~w(rabbit bird hamster reptile fish) do
        assert {:ok, pet} =
                 Pets.create_pet(owner, valid_pet_attributes(%{"species" => species}))

        assert pet.species == species
      end

      assert {:error, changeset} =
               Pets.create_pet(owner, valid_pet_attributes(%{"species" => "dragon"}))

      assert %{species: _} = errors_on(changeset)
    end
  end

  describe "authorization" do
    setup do
      owner = user_fixture()
      pet = pet_fixture(owner)
      %{owner: owner, pet: pet}
    end

    test "owner has read/write/manage", %{owner: owner, pet: pet} do
      assert Pets.can?(pet, owner, :read)
      assert Pets.can?(pet, owner, :write)
      assert Pets.can?(pet, owner, :manage)
    end

    test "co_caretaker can read and write but not manage", %{owner: owner, pet: pet} do
      co = user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")
      assert Pets.can?(pet, co, :read)
      assert Pets.can?(pet, co, :write)
      refute Pets.can?(pet, co, :manage)
    end

    test "viewer can only read", %{owner: owner, pet: pet} do
      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")
      assert Pets.can?(pet, viewer, :read)
      refute Pets.can?(pet, viewer, :write)
      refute Pets.can?(pet, viewer, :manage)
    end

    test "a stranger has no access", %{pet: pet} do
      stranger = user_fixture()
      refute Pets.can?(pet, stranger, :read)
      assert Pets.effective_role(pet, stranger) == nil
    end

    test "a revoked grant confers no access", %{owner: owner, pet: pet} do
      co = user_fixture()
      access = grant_fixture(pet, owner, co, "co_caretaker")
      {:ok, _} = Pets.revoke_access(owner, pet, access)
      refute Pets.can?(pet, co, :read)
    end

    test "an expired grant confers no access", %{owner: owner, pet: pet} do
      vet = user_fixture()
      grant_fixture(pet, owner, vet, "vet")

      # Force the grant into the past.
      Repo.update_all(PetAccess,
        set: [
          expires_at: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        ]
      )

      refute Pets.can?(pet, vet, :read)
    end
  end

  describe "fetch_pet/3 (IDOR-hidden)" do
    test "returns not_found for a pet the user cannot access" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      stranger = user_fixture()
      assert Pets.fetch_pet(stranger, pet.id) == {:error, :not_found}
    end

    test "enforces the required capability" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")
      assert {:ok, _} = Pets.fetch_pet(viewer, pet.id, require: :read)
      assert Pets.fetch_pet(viewer, pet.id, require: :manage) == {:error, :not_found}
    end
  end

  describe "grant/revoke" do
    test "grant by @handle resolves the user" do
      owner = user_fixture()

      {:ok, grantee} =
        Goodmao2.Accounts.update_user_profile(user_fixture(), %{"handle" => "dr_lin"})

      verified_vet_profile_fixture(grantee)
      pet = pet_fixture(owner)

      assert {:ok, _} =
               Pets.grant_access(owner, pet, %{"identifier" => "@dr_lin", "role" => "vet"})

      assert Pets.effective_role(pet, grantee) == "vet"
    end

    test "grant with an unknown identifier returns grantee_not_found" do
      owner = user_fixture()
      pet = pet_fixture(owner)

      assert Pets.grant_access(owner, pet, %{
               "identifier" => "nobody@nowhere.test",
               "role" => "viewer"
             }) ==
               {:error, :grantee_not_found}
    end

    test "granting the vet role is refused unless the grantee has a verified profile" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grantee = user_fixture()

      # No profile at all.
      assert Pets.grant_access(owner, pet, %{"identifier" => grantee.email, "role" => "vet"}) ==
               {:error, :vet_not_verified}

      # A pending (unverified) profile is still not enough.
      vet_profile_fixture(grantee)

      assert Pets.grant_access(owner, pet, %{"identifier" => grantee.email, "role" => "vet"}) ==
               {:error, :vet_not_verified}

      refute Pets.effective_role(pet, grantee)
    end

    test "granting the vet role succeeds for a verified vet" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grantee = user_fixture()
      verified_vet_profile_fixture(grantee)

      assert {:ok, _} =
               Pets.grant_access(owner, pet, %{"identifier" => grantee.email, "role" => "vet"})

      assert Pets.effective_role(pet, grantee) == "vet"
    end

    test "promoting an existing grant to vet is gated too (re-grant path)" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grantee = user_fixture()
      grant_fixture(pet, owner, grantee, "viewer")

      # The re-grant (insert_or_update) path must also enforce verification.
      assert Pets.grant_access(owner, pet, %{"identifier" => grantee.email, "role" => "vet"}) ==
               {:error, :vet_not_verified}

      assert Pets.effective_role(pet, grantee) == "viewer"

      verified_vet_profile_fixture(grantee)

      assert {:ok, _} =
               Pets.grant_access(owner, pet, %{"identifier" => grantee.email, "role" => "vet"})

      assert Pets.effective_role(pet, grantee) == "vet"
    end

    test "a non-manager cannot grant access" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")
      other = user_fixture()

      assert Pets.grant_access(viewer, pet, %{"identifier" => other.email, "role" => "viewer"}) ==
               {:error, :unauthorized}
    end

    test "revoking the last owner is refused" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      access = Pets.effective_access(pet, owner)
      assert Pets.revoke_access(owner, pet, access) == {:error, :last_owner}
    end

    test "revoking an owner is allowed when another owner remains" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      co_owner = user_fixture()
      grant_fixture(pet, owner, co_owner, "owner")

      access = Pets.effective_access(pet, owner)
      assert {:ok, _} = Pets.revoke_access(co_owner, pet, access)
    end

    test "the grant-update path cannot demote the last owner" do
      owner = user_fixture()
      pet = pet_fixture(owner)

      assert Pets.grant_access(owner, pet, %{"identifier" => owner.email, "role" => "viewer"}) ==
               {:error, :last_owner}

      # The owner grant is untouched.
      assert Pets.effective_role(pet, owner) == "owner"
    end

    test "the grant-update path cannot time-box the last owner" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      future = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      assert Pets.grant_access(owner, pet, %{
               "identifier" => owner.email,
               "role" => "owner",
               "expires_at" => future
             }) == {:error, :last_owner}
    end

    test "demoting an owner via the grant path is allowed when another owner remains" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      co_owner = user_fixture()
      grant_fixture(pet, owner, co_owner, "owner")

      assert {:ok, _} =
               Pets.grant_access(owner, pet, %{"identifier" => owner.email, "role" => "viewer"})

      assert Pets.effective_role(pet, owner) == "viewer"
    end
  end

  describe "list_pets/2 and lifecycle" do
    test "lists active pets and, separately, ended pets" do
      owner = user_fixture()
      active = pet_fixture(owner, %{"name" => "Alive"})
      ended = pet_fixture(owner, %{"name" => "Memorial"})
      {:ok, _} = Pets.update_pet_lifecycle(owner, ended, %{"lifecycle_status" => "passed_away"})

      active_ids = Pets.list_pets(owner) |> Enum.map(& &1.id)
      ended_ids = Pets.list_pets(owner, ended: true) |> Enum.map(& &1.id)

      assert active.id in active_ids
      refute ended.id in active_ids
      assert ended.id in ended_ids
    end

    test "ending care stamps ended_at and is reversible" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      {:ok, ended} = Pets.update_pet_lifecycle(owner, pet, %{"lifecycle_status" => "rehomed"})
      assert ended.ended_at

      {:ok, revived} = Pets.update_pet_lifecycle(owner, ended, %{"lifecycle_status" => "active"})
      assert revived.ended_at == nil
    end
  end
end
