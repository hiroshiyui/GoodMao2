defmodule Goodmao2.LogsTest do
  use Goodmao2.DataCase, async: true

  alias Goodmao2.Logs

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  setup do
    owner = user_fixture()
    pet = pet_fixture(owner)
    %{owner: owner, pet: pet}
  end

  describe "create_entry/3" do
    test "creates a typed entry and keeps the structured payload", %{owner: owner, pet: pet} do
      assert {:ok, entry} =
               Logs.create_entry(owner, pet, %{
                 "type" => "weight",
                 "data" => %{"weight_grams" => "4200"}
               })

      assert entry.type == "weight"
      assert entry.data["weight_grams"] == 4200
      assert entry.recorded_by_user_id == owner.id
    end

    test "rejects a payload missing a required structured field", %{owner: owner, pet: pet} do
      assert {:error, changeset} =
               Logs.create_entry(owner, pet, %{"type" => "weight", "data" => %{}})

      assert %{data: _} = errors_on(changeset)
    end

    test "rejects an invalid enum value", %{owner: owner, pet: pet} do
      assert {:error, changeset} =
               Logs.create_entry(owner, pet, %{"type" => "food", "data" => %{"amount" => "loads"}})

      assert %{data: _} = errors_on(changeset)
    end

    test "rejects a future occurred_at", %{owner: owner, pet: pet} do
      future = DateTime.utc_now() |> DateTime.add(1, :day) |> DateTime.truncate(:second)

      assert {:error, changeset} =
               Logs.create_entry(owner, pet, %{
                 "type" => "food",
                 "data" => %{"amount" => "full"},
                 "occurred_at" => future
               })

      assert %{occurred_at: _} = errors_on(changeset)
    end

    test "a viewer cannot write", %{owner: owner, pet: pet} do
      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      assert Logs.create_entry(viewer, pet, %{"type" => "food", "data" => %{"amount" => "full"}}) ==
               {:error, :unauthorized}
    end

    test "only a vet may author a vet_note", %{owner: owner, pet: pet} do
      assert Logs.create_entry(owner, pet, %{
               "type" => "vet_note",
               "data" => %{"assessment" => "stable"}
             }) ==
               {:error, :unauthorized}

      vet = user_fixture()
      grant_fixture(pet, owner, vet, "vet")

      assert {:ok, _} =
               Logs.create_entry(vet, pet, %{
                 "type" => "vet_note",
                 "data" => %{"assessment" => "stable"}
               })
    end
  end

  describe "list_entries/2" do
    test "returns live entries newest first and hides soft-deleted ones", %{
      owner: owner,
      pet: pet
    } do
      earlier = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

      _older =
        log_entry_fixture(owner, pet, %{
          "type" => "food",
          "data" => %{"amount" => "full"},
          "occurred_at" => earlier
        })

      newer =
        log_entry_fixture(owner, pet, %{"type" => "water", "data" => %{"amount" => "normal"}})

      assert hd(Logs.list_entries(owner, pet)).id == newer.id

      {:ok, _} = Logs.delete_entry(owner, pet, newer)
      refute newer.id in (Logs.list_entries(owner, pet) |> Enum.map(& &1.id))
    end

    test "filters by type", %{owner: owner, pet: pet} do
      log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      log_entry_fixture(owner, pet, %{"type" => "water", "data" => %{"amount" => "normal"}})

      types = Logs.list_entries(owner, pet, type: "water") |> Enum.map(& &1.type) |> Enum.uniq()
      assert types == ["water"]
    end
  end

  describe "history_hidden (ADR-0003)" do
    setup %{owner: owner, pet: pet} do
      log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      {:ok, hidden} = Goodmao2.Pets.update_pet(owner, pet, %{"history_hidden" => true})
      %{hidden: hidden}
    end

    test "hides the timeline from every role, including the owner", %{
      owner: owner,
      hidden: hidden
    } do
      assert Logs.list_entries(owner, hidden) == []
    end

    test "refuses writes while hidden", %{owner: owner, hidden: hidden} do
      assert Logs.create_entry(owner, hidden, %{
               "type" => "water",
               "data" => %{"amount" => "normal"}
             }) ==
               {:error, :unauthorized}
    end

    test "reads return again once un-hidden", %{owner: owner, hidden: hidden} do
      {:ok, shown} = Goodmao2.Pets.update_pet(owner, hidden, %{"history_hidden" => false})
      assert length(Logs.list_entries(owner, shown)) == 1
    end
  end

  describe "per-entry visibility (ADR-0004)" do
    test "a private entry is hidden from other followers but visible to owner and recorder", %{
      owner: owner,
      pet: pet
    } do
      co = user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")

      # The co-caretaker records a private entry; only owners and the recorder see it.
      {:ok, private} =
        Logs.create_entry(co, pet, %{
          "type" => "food",
          "data" => %{"amount" => "full"},
          "visibility" => "private"
        })

      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      refute private.id in (Logs.list_entries(viewer, pet) |> Enum.map(& &1.id))
      assert Logs.get_entry(viewer, pet, private.id) == nil

      assert private.id in (Logs.list_entries(owner, pet) |> Enum.map(& &1.id))
      assert private.id in (Logs.list_entries(co, pet) |> Enum.map(& &1.id))
      assert Logs.get_entry(owner, pet, private.id).id == private.id
    end

    test "only an owner may change visibility", %{owner: owner, pet: pet} do
      co = user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")
      entry = log_entry_fixture(co, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      assert Logs.update_entry(co, pet, entry, %{"visibility" => "private"}) ==
               {:error, :unauthorized}

      assert {:ok, updated} = Logs.update_entry(owner, pet, entry, %{"visibility" => "private"})
      assert updated.visibility == "private"
    end
  end

  describe "edit/delete authorization (ADR-0009)" do
    test "a co-caretaker cannot edit or delete another caretaker's entry", %{
      owner: owner,
      pet: pet
    } do
      other = user_fixture()
      grant_fixture(pet, owner, other, "co_caretaker")
      # Recorded by the owner, not by `other`.
      entry = log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      assert Logs.update_entry(other, pet, entry, %{"note" => "changed"}) ==
               {:error, :unauthorized}

      assert Logs.delete_entry(other, pet, entry) == {:error, :unauthorized}
    end

    test "a caretaker may edit and delete their own entry", %{owner: owner, pet: pet} do
      co = user_fixture()
      grant_fixture(pet, owner, co, "co_caretaker")
      entry = log_entry_fixture(co, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      assert {:ok, _} = Logs.update_entry(co, pet, entry, %{"note" => "mine"})
      assert {:ok, _} = Logs.delete_entry(co, pet, entry)
    end

    test "an owner may delete any entry, including a vet's vet_note", %{owner: owner, pet: pet} do
      vet = user_fixture()
      grant_fixture(pet, owner, vet, "vet")

      note =
        log_entry_fixture(vet, pet, %{"type" => "vet_note", "data" => %{"assessment" => "ok"}})

      # The owner cannot *edit* a vet_note (vet-only to write), but may delete it.
      assert Logs.update_entry(owner, pet, note, %{"note" => "no"}) == {:error, :unauthorized}
      assert {:ok, _} = Logs.delete_entry(owner, pet, note)
    end
  end

  describe "pubsub" do
    test "broadcasts on create", %{owner: owner, pet: pet} do
      Logs.subscribe(pet)

      {:ok, entry} =
        Logs.create_entry(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      assert_receive {:entry_created, %{id: id}}
      assert id == entry.id
    end
  end
end
