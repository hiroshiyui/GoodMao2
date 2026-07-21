defmodule Goodmao2.Notifications.FanoutWorkersTest do
  use Goodmao2.DataCase
  use Oban.Testing, repo: Goodmao2.Repo

  alias Goodmao2.Notifications
  alias Goodmao2.Notifications.{AnnouncementFanoutWorker, LogFanoutWorker}

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  describe "LogFanoutWorker" do
    test "notifies every other follower who may view the entry, never the author" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      co = user_fixture()
      viewer = user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")
      grant_fixture(pet, owner, viewer, "viewer")

      entry = log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      assert :ok = perform_job(LogFanoutWorker, %{"pet_id" => pet.id, "entry_id" => entry.id})

      # The two other followers get a log_added notification; the author (owner) does not.
      # (Grants themselves also notify, so count log_added specifically.)
      assert log_added_count(co) == 1
      assert log_added_count(viewer) == 1
      assert log_added_count(owner) == 0

      assert [n] = log_added_notifications(co)
      assert n.payload["entry_id"] == entry.id
      assert n.payload["log_type"] == "food"
    end

    test "a private entry does not notify a follower who cannot see it" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      co = user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")

      # Owner records a private entry — visible to the owner (author) only.
      private =
        log_entry_fixture(owner, pet, %{
          "type" => "symptom",
          "visibility" => "private",
          "data" => %{"symptom" => "secret", "severity" => 2}
        })

      assert :ok =
               perform_job(LogFanoutWorker, %{"pet_id" => pet.id, "entry_id" => private.id})

      # The co-caretaker cannot view the private entry, so gets no log_added notification.
      assert log_added_count(co) == 0
    end

    test "is a no-op for a soft-deleted entry" do
      owner = user_fixture()
      pet = pet_fixture(owner)
      co = user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")

      entry = log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      {:ok, _} = Goodmao2.Logs.delete_entry(owner, pet, entry)

      assert :ok = perform_job(LogFanoutWorker, %{"pet_id" => pet.id, "entry_id" => entry.id})
      assert log_added_count(co) == 0
    end
  end

  describe "AnnouncementFanoutWorker" do
    test "notifies every user" do
      a = user_fixture()
      b = user_fixture()
      c = user_fixture()

      assert :ok =
               perform_job(AnnouncementFanoutWorker, %{"title" => "Maintenance", "body" => "Soon"})

      for user <- [a, b, c] do
        assert [n] = Notifications.list_notifications(user)
        assert n.type == "announcement"
        assert n.payload["title"] == "Maintenance"
      end
    end
  end

  defp log_added_notifications(user),
    do: Enum.filter(Notifications.list_notifications(user), &(&1.type == "log_added"))

  defp log_added_count(user), do: length(log_added_notifications(user))
end
