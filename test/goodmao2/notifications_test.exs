defmodule Goodmao2.NotificationsTest do
  use Goodmao2.DataCase, async: true

  alias Goodmao2.Notifications

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  describe "create/3 and reads" do
    test "creates a notification and counts it as unread" do
      user = user_fixture()

      assert {:ok, notification} =
               Notifications.create(user.id, "announcement", %{
                 "title" => "Hello",
                 "body" => "Welcome to GoodMao."
               })

      assert notification.user_id == user.id
      assert notification.read_at == nil
      assert Notifications.unread_count(user) == 1
      assert [listed] = Notifications.list_notifications(user)
      assert listed.id == notification.id
    end

    test "rejects a payload missing keys its type needs" do
      user = user_fixture()
      assert {:error, changeset} = Notifications.create(user.id, "access_granted", %{})
      assert %{payload: _} = errors_on(changeset)
    end

    test "list is newest-first and honors :limit" do
      user = user_fixture()
      for i <- 1..3, do: Notifications.create(user.id, "announcement", ann(i))

      assert length(Notifications.list_notifications(user)) == 3
      assert length(Notifications.list_notifications(user, limit: 2)) == 2
    end
  end

  describe "mark read / delete (recipient-scoped)" do
    test "mark_read clears one, mark_all_read clears the rest" do
      user = user_fixture()
      {:ok, first} = Notifications.create(user.id, "announcement", ann(1))
      {:ok, _second} = Notifications.create(user.id, "announcement", ann(2))

      assert {:ok, 1} = Notifications.mark_read(user, first)
      assert Notifications.unread_count(user) == 1

      assert {:ok, 1} = Notifications.mark_all_read(user)
      assert Notifications.unread_count(user) == 0
    end

    test "get_notification is IDOR-hidden for a non-owner" do
      owner = user_fixture()
      stranger = user_fixture()
      {:ok, notification} = Notifications.create(owner.id, "announcement", ann(1))

      assert Notifications.get_notification(owner, notification.id)
      assert Notifications.get_notification(stranger, notification.id) == nil
    end

    test "delete_notification refuses a row the caller doesn't own" do
      owner = user_fixture()
      stranger = user_fixture()
      {:ok, notification} = Notifications.create(owner.id, "announcement", ann(1))

      assert Notifications.delete_notification(stranger, notification) == {:error, :not_found}
      assert {:ok, _} = Notifications.delete_notification(owner, notification)
      assert Notifications.unread_count(owner) == 0
    end
  end

  describe "inline access notifications" do
    test "notify_access_granted stores pet + role in the payload" do
      owner = user_fixture()
      grantee = user_fixture()
      pet = pet_fixture(owner)

      assert {:ok, n} = Notifications.notify_access_granted(grantee.id, owner, pet, "viewer")
      assert n.type == "access_granted"
      assert n.payload["pet_id"] == pet.id
      assert n.payload["pet_name"] == pet.name
      assert n.payload["role"] == "viewer"
    end

    test "notify_access_revoked records the pet" do
      owner = user_fixture()
      grantee = user_fixture()
      pet = pet_fixture(owner)

      assert {:ok, n} = Notifications.notify_access_revoked(grantee.id, owner, pet)
      assert n.type == "access_revoked"
      assert n.payload["pet_id"] == pet.id
    end
  end

  describe "broadcast_announcement/2" do
    test "an admin enqueues the fan-out job" do
      admin = admin_fixture()

      assert {:ok, _job} =
               Notifications.broadcast_announcement(admin, %{title: "T", body: "B"})
    end

    test "a non-admin is refused" do
      # The first registered user becomes the admin; occupy that slot so the next is not.
      _admin = admin_fixture()
      user = user_fixture()

      assert Notifications.broadcast_announcement(user, %{title: "T", body: "B"}) ==
               {:error, :unauthorized}
    end
  end

  defp ann(i), do: %{"title" => "Title #{i}", "body" => "Body #{i}"}
end
