defmodule Goodmao2.MediaTest do
  # async: false — these tests write real objects into the shared test storage dir and shell
  # out to ffmpeg.
  use Goodmao2.DataCase, async: false

  alias Goodmao2.{Logs, Media}
  alias Goodmao2.Media.Storage

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  # Attach a ready asset directly (bypassing the async pipeline) — for read/serve-focused tests.
  defp attach_asset(user, pet, purified, attrs \\ %{"note" => "hi"}) do
    {:ok, entry} = Logs.create_entry(user, pet, Map.put(attrs, "type", "life"))

    {:ok, asset} =
      Media.attach_purified_asset(
        %{log_entry_id: entry.id, pet_id: pet.id, uploaded_by_user_id: user.id, caption: nil},
        purified
      )

    {entry, asset}
  end

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

  describe "create_life_log/4 (async pipeline)" do
    test "stages media, creates the entry immediately, and the worker attaches it", %{
      owner: owner,
      pet: pet
    } do
      {:ok, token} = Media.stage_upload(make_png())

      assert {:ok, entry} =
               Media.create_life_log(owner, pet, %{"note" => "Nap in the sun"}, [%{token: token}])

      # The entry lands right away with no media yet — purification runs in the background.
      assert entry.type == "life"
      assert entry.media_assets == []
      assert File.exists?(Storage.staged_path(token))

      # Draining the queue runs the PurifyWorker, which attaches the ready asset.
      Oban.drain_queue(queue: :default)

      [asset] = Goodmao2.Repo.all(from a in Media.MediaAsset, where: a.log_entry_id == ^entry.id)
      assert asset.kind == "image"
      assert asset.pet_id == pet.id
      assert Storage.exists?(asset.id)
      # The staged raw bytes were cleaned up.
      refute File.exists?(Storage.staged_path(token))
    end

    test "refuses a viewer and hidden history (before staging matters)", %{owner: owner, pet: pet} do
      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      assert Media.create_life_log(viewer, pet, %{"note" => "no"}, []) == {:error, :unauthorized}

      {:ok, hidden} = Goodmao2.Pets.update_pet(owner, pet, %{"history_hidden" => true})

      assert Media.create_life_log(owner, hidden, %{"note" => "no"}, []) ==
               {:error, :unauthorized}
    end

    test "a note is still required", %{owner: owner, pet: pet} do
      assert {:error, %Ecto.Changeset{}} = Media.create_life_log(owner, pet, %{"note" => ""}, [])
    end

    test "a bad staged file notifies the uploader and leaves no asset", %{owner: owner, pet: pet} do
      bad = tmp("png")
      File.write!(bad, "not really a png")
      on_exit(fn -> File.rm(bad) end)
      {:ok, token} = Media.stage_upload(bad)

      {:ok, entry} = Media.create_life_log(owner, pet, %{"note" => "oops"}, [%{token: token}])
      Oban.drain_queue(queue: :default)

      assert [] ==
               Goodmao2.Repo.all(from a in Media.MediaAsset, where: a.log_entry_id == ^entry.id)

      refute File.exists?(Storage.staged_path(token))
      # The uploader got a media_failed bell.
      assert Enum.any?(
               Goodmao2.Notifications.list_notifications(owner),
               &(&1.type == "media_failed")
             )
    end
  end

  describe "fetch_asset_for_user/2" do
    setup %{owner: owner, pet: pet} do
      {:ok, purified} = Media.purify(make_png())
      on_exit(fn -> File.rm(purified.path) end)
      {_entry, asset} = attach_asset(owner, pet, purified)
      %{asset: asset}
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

      {_entry, asset} =
        attach_asset(owner, pet, purified, %{"note" => "secret", "visibility" => "private"})

      viewer = user_fixture()
      grant_fixture(pet, owner, viewer, "viewer")

      assert Media.fetch_asset_for_user(viewer, asset.id) == {:error, :not_found}
    end
  end

  describe "delete_orphans/1" do
    test "removes stored objects with no row and stale staged files, keeping live ones", %{
      owner: owner,
      pet: pet
    } do
      {:ok, purified} = Media.purify(make_png())
      on_exit(fn -> File.rm(purified.path) end)
      {_entry, live} = attach_asset(owner, pet, purified)

      # An orphaned stored object (an id with no row) and a stale staged file.
      orphan_id = live.id + 987
      Storage.store(orphan_id, live_bytes(live))
      {:ok, stale_token} = Media.stage_upload(live_bytes(live))

      # Sweep everything regardless of age (age 0).
      assert %{objects: objects, staged: staged} = Media.delete_orphans(0)
      assert objects >= 1
      assert staged >= 1

      # The live asset's bytes survive; the orphan and staged bytes are gone.
      assert Storage.exists?(live.id)
      refute Storage.exists?(orphan_id)
      refute File.exists?(Storage.staged_path(stale_token))
    end
  end

  # Copies a live asset's stored bytes to a temp file (a convenient source of real object bytes).
  defp live_bytes(asset) do
    src = Storage.object_path(asset.id)
    dst = tmp("bin")
    File.cp!(src, dst)
    on_exit(fn -> File.rm(dst) end)
    dst
  end
end
