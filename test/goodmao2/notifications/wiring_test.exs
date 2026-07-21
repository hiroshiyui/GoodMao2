defmodule Goodmao2.Notifications.WiringTest do
  @moduledoc "The existing Pets/Logs events create/enqueue notifications."
  use Goodmao2.DataCase
  use Oban.Testing, repo: Goodmao2.Repo

  alias Goodmao2.{Logs, Notifications, Pets}
  alias Goodmao2.Notifications.LogFanoutWorker

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  describe "access grant/revoke" do
    test "granting access notifies the grantee inline" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grantee = user_fixture()

      {:ok, _} =
        Pets.grant_access(owner, pet, %{"identifier" => grantee.email, "role" => "viewer"})

      assert [n] = Notifications.list_notifications(grantee)
      assert n.type == "access_granted"
      assert n.payload["pet_id"] == pet.id
    end

    test "a pure no-op re-grant does not notify again" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grantee = user_fixture()

      attrs = %{"identifier" => grantee.email, "role" => "viewer"}
      {:ok, _} = Pets.grant_access(owner, pet, attrs)
      {:ok, _} = Pets.grant_access(owner, pet, attrs)

      assert Notifications.unread_count(grantee) == 1
    end

    test "a role change re-notifies" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grantee = user_fixture()

      {:ok, _} =
        Pets.grant_access(owner, pet, %{"identifier" => grantee.email, "role" => "viewer"})

      {:ok, _} =
        Pets.grant_access(owner, pet, %{"identifier" => grantee.email, "role" => "co_caretaker"})

      assert Notifications.unread_count(grantee) == 2
    end

    test "revoking access notifies the revoked user" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      grantee = user_fixture()
      access = grant_fixture(pet, owner, grantee, "viewer")

      {:ok, _} = Pets.revoke_access(owner, pet, access)

      types = Enum.map(Notifications.list_notifications(grantee), & &1.type)
      assert "access_revoked" in types
    end
  end

  describe "log creation" do
    test "creating an entry enqueues the log fan-out job" do
      owner = user_fixture()
      pet = pet_fixture(owner)

      {:ok, entry} =
        Logs.create_entry(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      assert_enqueued(
        worker: LogFanoutWorker,
        args: %{"pet_id" => pet.id, "entry_id" => entry.id}
      )
    end
  end
end
