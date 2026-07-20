defmodule Goodmao2.ReportsTest do
  use Goodmao2.DataCase, async: true

  alias Goodmao2.Reports

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  setup do
    owner = user_fixture()
    pet = pet_fixture(owner)
    %{owner: owner, pet: pet}
  end

  defp today_range, do: %{period_start: Date.utc_today(), period_end: Date.utc_today()}

  describe "generate_report/3" do
    test "freezes a snapshot of the range", %{owner: owner, pet: pet} do
      log_entry_fixture(owner, pet, %{"type" => "food", "data" => %{"amount" => "full"}})

      assert {:ok, report} = Reports.generate_report(owner, pet, today_range())
      assert report.pet_id == pet.id
      assert report.generated_by_user_id == owner.id
      assert [entry] = report.content["entries"]
      assert entry["type"] == "food"
    end

    test "omits private entries even when the owner generates it", %{owner: owner, pet: pet} do
      log_entry_fixture(owner, pet, %{"type" => "food", "visibility" => "limited"})

      log_entry_fixture(owner, pet, %{
        "type" => "symptom",
        "visibility" => "private",
        "data" => %{"symptom" => "secret", "severity" => 2}
      })

      {:ok, report} = Reports.generate_report(owner, pet, today_range())
      types = Enum.map(report.content["entries"], & &1["type"])
      assert "food" in types
      refute "symptom" in types
    end

    test "returns an empty snapshot when history is hidden", %{owner: owner, pet: pet} do
      log_entry_fixture(owner, pet, %{"type" => "food"})
      {:ok, pet} = Goodmao2.Pets.update_pet(owner, pet, %{"history_hidden" => true})

      {:ok, report} = Reports.generate_report(owner, pet, today_range())
      assert report.content["entries"] == []
    end

    test "requires :manage", %{pet: pet} do
      viewer = user_fixture()
      grant_fixture(pet, hd(owners(pet)), viewer, "viewer")
      assert Reports.generate_report(viewer, pet, today_range()) == {:error, :unauthorized}
    end
  end

  describe "fetch_report/3" do
    test "is IDOR-hidden for a pet the caller cannot read", %{owner: owner, pet: pet} do
      {:ok, report} = Reports.generate_report(owner, pet, today_range())
      stranger = user_fixture()
      assert Reports.fetch_report(stranger, pet, report.id) == nil
    end

    test "a reader (vet) can fetch it", %{owner: owner, pet: pet} do
      {:ok, report} = Reports.generate_report(owner, pet, today_range())
      vet = user_fixture()
      grant_fixture(pet, owner, vet, "vet")
      assert %{id: id} = Reports.fetch_report(vet, pet, report.id)
      assert id == report.id
    end
  end

  describe "share token" do
    test "valid token resolves; expired, revoked, and deleted do not", %{owner: owner, pet: pet} do
      {:ok, report} = Reports.generate_report(owner, pet, today_range())

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      {:ok, {report, token}} = Reports.create_share_token(owner, pet, report, future)
      assert %{id: id} = Reports.fetch_report_by_token(token)
      assert id == report.id

      # Garbage token.
      assert Reports.fetch_report_by_token("not-a-real-token") == nil

      # Revoked.
      {:ok, revoked} = Reports.revoke_share_token(owner, pet, report)
      assert Reports.fetch_report_by_token(token) == nil

      # Re-mint, then expire it.
      {:ok, {report, token2}} = Reports.create_share_token(owner, pet, revoked, future)
      past = DateTime.add(DateTime.utc_now(), -10, :second)

      report
      |> Ecto.Changeset.change(%{share_expires_at: DateTime.truncate(past, :second)})
      |> Repo.update!()

      assert Reports.fetch_report_by_token(token2) == nil
    end

    test "an expiry in the past is refused", %{owner: owner, pet: pet} do
      {:ok, report} = Reports.generate_report(owner, pet, today_range())
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      assert Reports.create_share_token(owner, pet, report, past) == {:error, :expiry_in_past}
    end

    test "creating a share token requires :manage", %{owner: owner, pet: pet} do
      {:ok, report} = Reports.generate_report(owner, pet, today_range())
      vet = user_fixture()
      grant_fixture(pet, owner, vet, "vet")
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert Reports.create_share_token(vet, pet, report, future) == {:error, :unauthorized}
    end
  end

  describe "delete_report/3" do
    test "soft-deletes and hides the report", %{owner: owner, pet: pet} do
      {:ok, report} = Reports.generate_report(owner, pet, today_range())
      assert {:ok, _} = Reports.delete_report(owner, pet, report)
      assert Reports.fetch_report(owner, pet, report.id) == nil
      assert Reports.list_reports(owner, pet) == []
    end
  end

  defp owners(pet) do
    pet
    |> Goodmao2.Pets.list_accesses()
    |> Enum.filter(&(&1.role == "owner"))
    |> Enum.map(& &1.user)
  end
end
