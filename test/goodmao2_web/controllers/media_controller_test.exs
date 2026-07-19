defmodule Goodmao2Web.MediaControllerTest do
  # async: false — writes real objects into the shared test storage dir and shells to ffmpeg.
  use Goodmao2Web.ConnCase, async: false

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  alias Goodmao2.Media
  alias Goodmao2.Media.Storage

  setup do
    File.rm_rf(Storage.storage_dir())
    :ok
  end

  defp make_asset(owner, pet, opts \\ []) do
    src = Path.join(System.tmp_dir!(), "gm_ct_#{System.unique_integer([:positive])}.png")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -v error -f lavfi -i color=c=blue:s=16x16 -frames:v 1 -y) ++ [src]
      )

    {:ok, purified} = Media.purify(src)
    File.rm(src)

    attrs = %{"note" => "hi", "visibility" => Keyword.get(opts, :visibility, "limited")}
    {:ok, entry} = Media.create_life_log_with_media(owner, pet, attrs, [purified])
    File.rm(purified.path)
    hd(entry.media_assets)
  end

  test "serves bytes to an authorized reader with hardened headers", %{conn: conn} do
    owner = user_fixture()
    pet = pet_fixture(owner)
    asset = make_asset(owner, pet)

    conn = conn |> log_in_user(owner) |> get(~p"/media/#{asset.id}")

    assert response(conn, 200)
    assert byte_size(response(conn, 200)) == asset.byte_size
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-disposition") == ["inline"]
    assert ["default-src 'none'; sandbox"] = get_resp_header(conn, "content-security-policy")
  end

  test "hides an inaccessible asset as not found (IDOR)", %{conn: conn} do
    owner = user_fixture()
    pet = pet_fixture(owner)
    asset = make_asset(owner, pet)

    stranger = user_fixture()
    conn = conn |> log_in_user(stranger) |> get(~p"/media/#{asset.id}")
    assert conn.status == 404
  end

  test "requires authentication", %{conn: conn} do
    owner = user_fixture()
    pet = pet_fixture(owner)
    asset = make_asset(owner, pet)

    conn = get(conn, ~p"/media/#{asset.id}")
    assert conn.status in [302, 401]
  end

  test "supports a Range request for seeking", %{conn: conn} do
    owner = user_fixture()
    pet = pet_fixture(owner)
    asset = make_asset(owner, pet)

    conn =
      conn
      |> log_in_user(owner)
      |> put_req_header("range", "bytes=0-9")
      |> get(~p"/media/#{asset.id}")

    assert conn.status == 206
    assert byte_size(response(conn, 206)) == 10
    assert [range] = get_resp_header(conn, "content-range")
    assert range == "bytes 0-9/#{asset.byte_size}"
  end
end
