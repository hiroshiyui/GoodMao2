defmodule Goodmao2Web.AvatarControllerTest do
  # async: false — writes real objects into the shared test storage dir and shells to ffmpeg.
  use Goodmao2Web.ConnCase, async: false

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  alias Goodmao2.Media
  alias Goodmao2.Media.{Avatars, Storage}

  setup do
    File.rm_rf(Storage.storage_dir())
    :ok
  end

  # Sets a ready avatar for an owner directly through the pipeline.
  defp set_ready_avatar(owner_type, owner_id, actor) do
    src = Path.join(System.tmp_dir!(), "gm_av_ct_#{System.unique_integer([:positive])}.png")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -v error -f lavfi -i color=c=green:s=16x16 -frames:v 1 -y) ++ [src]
      )

    {:ok, token} = Media.stage_upload(src)
    File.rm(src)
    {:ok, _} = Avatars.set_avatar(owner_type, owner_id, actor, token)
    Oban.drain_queue(queue: :default)
  end

  test "serves a user avatar to any authenticated user, hardened", %{conn: conn} do
    owner = user_fixture()
    set_ready_avatar("user", owner.id, owner)

    viewer = user_fixture()
    conn = conn |> log_in_user(viewer) |> get(~p"/avatars/user/#{owner.id}")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert ["default-src 'none'; sandbox"] = get_resp_header(conn, "content-security-policy")
  end

  test "requires authentication", %{conn: conn} do
    owner = user_fixture()
    set_ready_avatar("user", owner.id, owner)

    conn = get(conn, ~p"/avatars/user/#{owner.id}")
    assert conn.status in [302, 401]
  end

  test "serves a pet avatar to a reader but hides it from a stranger (IDOR)", %{conn: conn} do
    owner = user_fixture()
    pet = pet_fixture(owner)
    set_ready_avatar("pet", pet.id, owner)

    reader = user_fixture()
    grant_fixture(pet, owner, reader, "viewer")
    conn1 = conn |> log_in_user(reader) |> get(~p"/avatars/pet/#{pet.id}")
    assert response(conn1, 200)

    stranger = user_fixture()
    conn2 = build_conn() |> log_in_user(stranger) |> get(~p"/avatars/pet/#{pet.id}")
    assert conn2.status == 404
  end

  test "an owner with no avatar is 404", %{conn: conn} do
    owner = user_fixture()
    conn = conn |> log_in_user(owner) |> get(~p"/avatars/user/#{owner.id}")
    assert conn.status == 404
  end
end
