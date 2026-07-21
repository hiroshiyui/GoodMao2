defmodule Goodmao2Web.SharedEntryControllerTest do
  use Goodmao2Web.ConnCase, async: true

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  alias Goodmao2.Logs

  defp public_entry(attrs \\ %{}) do
    owner = user_fixture()
    pet = pet_fixture(owner)

    {:ok, entry} =
      Logs.create_entry(
        owner,
        pet,
        Enum.into(attrs, %{
          "type" => "symptom",
          "data" => %{"symptom" => "limping", "severity" => "3"},
          "note" => "front left paw",
          "visibility" => "public"
        })
      )

    %{owner: owner, pet: pet, entry: entry}
  end

  test "renders a public entry to an anonymous holder of the link", %{conn: conn} do
    %{entry: entry} = public_entry()

    conn = get(conn, ~p"/entries/shared/#{entry.share_token}")

    assert html = html_response(conn, 200)
    assert html =~ "Symptom"
    assert html =~ "front left paw"
    # No account was used.
    refute conn.assigns[:current_scope] && conn.assigns.current_scope.user
  end

  test "a bad token is existence-hidden (404)", %{conn: conn} do
    conn = get(conn, ~p"/entries/shared/#{"not-a-real-token"}")
    assert conn.status == 404
  end

  test "narrowing the entry revokes the link (404)", %{conn: conn} do
    %{owner: owner, pet: pet, entry: entry} = public_entry()
    {:ok, _} = Logs.update_entry(owner, pet, entry, %{"visibility" => "limited"})

    conn = get(conn, ~p"/entries/shared/#{entry.share_token}")
    assert conn.status == 404
  end

  test "an expired link is existence-hidden (404)", %{conn: conn} do
    %{owner: owner, pet: pet, entry: entry} = public_entry()
    future = DateTime.utc_now() |> DateTime.add(3600, :second)
    {:ok, entry} = Logs.set_share_expiry(owner, pet, entry, future)

    past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
    Ecto.Changeset.change(entry, share_expires_at: past) |> Goodmao2.Repo.update!()

    conn = get(conn, ~p"/entries/shared/#{entry.share_token}")
    assert conn.status == 404
  end
end
