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

    test "a caretaker may author a text-only life log", %{owner: owner, pet: pet} do
      assert {:ok, entry} =
               Logs.create_entry(owner, pet, %{"type" => "life", "note" => "Zoomies at dawn."})

      assert entry.type == "life"
      assert entry.note == "Zoomies at dawn."
    end

    test "a life log requires a caption (its content until media lands)", %{
      owner: owner,
      pet: pet
    } do
      assert {:error, changeset} = Logs.create_entry(owner, pet, %{"type" => "life"})
      assert %{note: ["can't be blank"]} = errors_on(changeset)
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

  describe "weight_series/3" do
    test "returns weight measurements oldest-first as at/grams", %{owner: owner, pet: pet} do
      earlier = DateTime.utc_now() |> DateTime.add(-2, :day) |> DateTime.truncate(:second)

      log_entry_fixture(owner, pet, %{
        "type" => "weight",
        "data" => %{"weight_grams" => 4200},
        "occurred_at" => earlier
      })

      log_entry_fixture(owner, pet, %{"type" => "weight", "data" => %{"weight_grams" => 4350}})

      # Non-weight entries are ignored.
      log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      series = Logs.weight_series(owner, pet)
      assert Enum.map(series, & &1.grams) == [4200, 4350]
      assert DateTime.compare(hd(series).at, List.last(series).at) == :lt
    end

    test "applies per-entry visibility (ADR-0004)", %{owner: owner, pet: pet} do
      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      {:ok, _private} =
        Logs.create_entry(owner, pet, %{
          "type" => "weight",
          "data" => %{"weight_grams" => 4200},
          "visibility" => "private"
        })

      assert Logs.weight_series(viewer, pet) == []
      assert [%{grams: 4200}] = Logs.weight_series(owner, pet)
    end

    test "is empty when history is hidden (ADR-0003)", %{owner: owner, pet: pet} do
      log_entry_fixture(owner, pet, %{"type" => "weight", "data" => %{"weight_grams" => 4200}})
      {:ok, hidden} = Goodmao2.Pets.update_pet(owner, pet, %{"history_hidden" => true})
      assert Logs.weight_series(owner, hidden) == []
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

  describe "edit revisions (ADR-0009)" do
    test "a real edit snapshots the prior state and increments edit_count", %{
      owner: owner,
      pet: pet
    } do
      entry =
        log_entry_fixture(owner, pet, %{
          "type" => "food",
          "data" => %{"amount" => "full"},
          "note" => "before"
        })

      assert {:ok, updated} = Logs.update_entry(owner, pet, entry, %{"note" => "after"})
      assert updated.edit_count == 1
      assert updated.note == "after"

      assert [rev] = Logs.list_revisions(owner, pet, updated)
      assert rev.snapshot["note"] == "before"
      assert rev.snapshot["type"] == "food"
      assert rev.edited_by_user_id == owner.id
    end

    test "a no-op edit records nothing", %{owner: owner, pet: pet} do
      entry =
        log_entry_fixture(owner, pet, %{
          "type" => "food",
          "data" => %{"amount" => "full"},
          "note" => "same"
        })

      assert {:ok, same} = Logs.update_entry(owner, pet, entry, %{"note" => "same"})
      assert same.edit_count == 0
      assert Logs.list_revisions(owner, pet, same) == []
    end

    test "the tenth edit is refused and leaves the entry at nine", %{owner: owner, pet: pet} do
      entry = log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      entry =
        Enum.reduce(1..Logs.max_edits(), entry, fn i, acc ->
          {:ok, next} = Logs.update_entry(owner, pet, acc, %{"note" => "edit #{i}"})
          next
        end)

      assert entry.edit_count == Logs.max_edits()

      assert Logs.update_entry(owner, pet, entry, %{"note" => "one too many"}) ==
               {:error, :edit_limit}

      assert length(Logs.list_revisions(owner, pet, entry)) == Logs.max_edits()
    end

    test "the type is immutable on edit", %{owner: owner, pet: pet} do
      entry = log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      assert {:ok, updated} =
               Logs.update_entry(owner, pet, entry, %{"type" => "water", "note" => "still food"})

      assert updated.type == "food"
    end

    test "history follows the entry's read authorization (ADR-0009)", %{owner: owner, pet: pet} do
      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      {:ok, private} =
        Logs.create_entry(owner, pet, %{
          "type" => "food",
          "data" => %{"amount" => "full"},
          "visibility" => "private"
        })

      {:ok, private} = Logs.update_entry(owner, pet, private, %{"note" => "edited"})

      # The owner sees the history; a viewer who can't see the private entry can't see it.
      assert [_rev] = Logs.list_revisions(owner, pet, private)
      assert Logs.list_revisions(viewer, pet, private) == []
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
