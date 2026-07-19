defmodule Goodmao2.MediaTest do
  # async: false — these tests write real objects into the shared test storage dir and shell
  # out to ffmpeg.
  use Goodmao2.DataCase, async: false

  alias Goodmao2.Media
  alias Goodmao2.Media.Storage

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  setup do
    File.rm_rf(Storage.storage_dir())
    owner = user_fixture()
    pet = pet_fixture(owner)
    %{owner: owner, pet: pet}
  end

  # --- Test media generators (real bytes via ffmpeg) -------------------------

  defp tmp(ext),
    do: Path.join(System.tmp_dir!(), "gm_test_#{System.unique_integer([:positive])}.#{ext}")

  defp make_png do
    path = tmp("png")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -v error -f lavfi -i color=c=red:s=16x16 -frames:v 1 -y) ++ [path]
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp make_mp4 do
    path = tmp("mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -v error -f lavfi -i testsrc=d=1:s=32x32:r=5 -c:v libx264 -pix_fmt yuv420p -t 1 -y) ++
          [path]
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp cleanup_purified({:ok, %{path: path}}), do: on_exit(fn -> File.rm(path) end)
  defp cleanup_purified(_), do: :ok

  describe "purify/1" do
    test "re-encodes a PNG into clean image bytes" do
      result = Media.purify(make_png())
      cleanup_purified(result)

      assert {:ok, %{kind: "image", content_type: "image/png", path: path, byte_size: size}} =
               result

      assert size > 0
      assert File.exists?(path)
    end

    test "purifies an h264 MP4 into clean video bytes" do
      result = Media.purify(make_mp4())
      cleanup_purified(result)

      assert {:ok, %{kind: "video", content_type: "video/mp4", byte_size: size}} = result
      assert size > 0
    end

    test "rejects a non-allow-listed type by magic bytes (not extension)" do
      # An SVG (active-content XML) disguised with an image extension is still rejected.
      path = tmp("png")

      File.write!(
        path,
        ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|
      )

      on_exit(fn -> File.rm(path) end)

      assert {:error, :unsupported_type} = Media.purify(path)
    end
  end

  describe "create_life_log_with_media/4" do
    test "creates a life log with a stored, purified image atomically", %{owner: owner, pet: pet} do
      {:ok, purified} = Media.purify(make_png())
      on_exit(fn -> File.rm(purified.path) end)

      assert {:ok, entry} =
               Media.create_life_log_with_media(owner, pet, %{"note" => "Nap in the sun"}, [
                 purified
               ])

      assert entry.type == "life"
      assert [asset] = entry.media_assets
      assert asset.kind == "image"
      assert asset.pet_id == pet.id
      # The bytes landed in storage, keyed by the asset id.
      assert Storage.exists?(asset.id)
    end

    test "refuses a viewer and hidden history", %{owner: owner, pet: pet} do
      {:ok, purified} = Media.purify(make_png())
      on_exit(fn -> File.rm(purified.path) end)

      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      assert Media.create_life_log_with_media(viewer, pet, %{"note" => "no"}, [purified]) ==
               {:error, :unauthorized}

      {:ok, hidden} = Goodmao2.Pets.update_pet(owner, pet, %{"history_hidden" => true})

      assert Media.create_life_log_with_media(owner, hidden, %{"note" => "no"}, [purified]) ==
               {:error, :unauthorized}
    end

    test "a note is still required (rolls back with no stored bytes)", %{owner: owner, pet: pet} do
      {:ok, purified} = Media.purify(make_png())
      on_exit(fn -> File.rm(purified.path) end)

      assert {:error, %Ecto.Changeset{}} =
               Media.create_life_log_with_media(owner, pet, %{"note" => ""}, [purified])
    end
  end

  describe "fetch_asset_for_user/2" do
    setup %{owner: owner, pet: pet} do
      {:ok, purified} = Media.purify(make_png())
      on_exit(fn -> File.rm(purified.path) end)
      {:ok, entry} = Media.create_life_log_with_media(owner, pet, %{"note" => "hi"}, [purified])
      %{asset: hd(entry.media_assets)}
    end

    test "the owner may read it; a stranger gets not_found", %{owner: owner, asset: asset} do
      assert {:ok, %{id: id}} = Media.fetch_asset_for_user(owner, asset.id)
      assert id == asset.id

      stranger = user_fixture()
      assert Media.fetch_asset_for_user(stranger, asset.id) == {:error, :not_found}
    end

    test "a private entry's media is hidden from a viewer (ADR-0004)", %{owner: owner, pet: pet} do
      {:ok, purified} = Media.purify(make_png())
      on_exit(fn -> File.rm(purified.path) end)

      {:ok, entry} =
        Media.create_life_log_with_media(
          owner,
          pet,
          %{"note" => "secret", "visibility" => "private"},
          [purified]
        )

      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      assert Media.fetch_asset_for_user(viewer, hd(entry.media_assets).id) == {:error, :not_found}
    end
  end
end
