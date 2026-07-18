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

      assert hd(Logs.list_entries(pet)).id == newer.id

      {:ok, _} = Logs.delete_entry(owner, pet, newer)
      refute newer.id in (Logs.list_entries(pet) |> Enum.map(& &1.id))
    end

    test "filters by type", %{owner: owner, pet: pet} do
      log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})
      log_entry_fixture(owner, pet, %{"type" => "water", "data" => %{"amount" => "normal"}})

      types = Logs.list_entries(pet, type: "water") |> Enum.map(& &1.type) |> Enum.uniq()
      assert types == ["water"]
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
