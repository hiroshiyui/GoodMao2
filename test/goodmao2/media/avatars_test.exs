defmodule Goodmao2.Media.AvatarsTest do
  # async: false — these tests write real objects into the shared test storage dir and shell
  # out to ffmpeg (mirroring MediaTest).
  use Goodmao2.DataCase, async: false

  alias Goodmao2.Media
  alias Goodmao2.Media.{Avatar, Avatars, Storage}

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  setup do
    File.rm_rf(Storage.storage_dir())
    owner = user_fixture()
    pet = pet_fixture(owner)
    %{owner: owner, pet: pet}
  end

  # A real PNG of the given size via ffmpeg, staged and ready for set_avatar.
  defp staged_png(spec \\ "16x16") do
    path = Path.join(System.tmp_dir!(), "gm_av_#{System.unique_integer([:positive])}.png")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -v error -f lavfi -i) ++
          ["color=c=blue:s=#{spec}"] ++ ~w(-frames:v 1 -y) ++ [path]
      )

    on_exit(fn -> File.rm(path) end)
    {:ok, token} = Media.stage_upload(path)
    token
  end

  defp object_dims(owner_type, owner_id) do
    path = Storage.avatar_object_path("#{owner_type}-#{owner_id}")

    {out, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0) ++ [path]
      )

    [w, h] = out |> String.trim() |> String.split(",")
    {String.to_integer(w), String.to_integer(h)}
  end

  describe "set_avatar/4 (async pipeline)" do
    test "a user sets their own avatar; the worker purifies and stores it", %{owner: owner} do
      token = staged_png()

      assert {:ok, %Avatar{status: "processing"} = avatar} =
               Avatars.set_avatar("user", owner.id, owner, token)

      assert avatar.owner_type == "user"
      assert avatar.owner_id == owner.id
      refute Storage.avatar_exists?("user-#{owner.id}")

      Oban.drain_queue(queue: :default)

      ready = Avatars.get_avatar("user", owner.id)
      assert ready.status == "ready"
      assert ready.content_type == "image/png"
      assert Storage.avatar_exists?("user-#{owner.id}")
      refute File.exists?(Storage.staged_path(token))
    end

    test "a manager sets a pet's avatar", %{owner: owner, pet: pet} do
      assert {:ok, %Avatar{}} = Avatars.set_avatar("pet", pet.id, owner, staged_png())
      Oban.drain_queue(queue: :default)
      assert Avatars.get_avatar("pet", pet.id).status == "ready"
    end

    test "a user cannot set someone else's avatar", %{owner: owner} do
      other = user_fixture()

      assert Avatars.set_avatar("user", other.id, owner, staged_png()) ==
               {:error, :unauthorized}

      assert Avatars.get_avatar("user", other.id) == nil
    end

    test "a non-manager cannot set a pet's avatar", %{pet: pet} do
      writer = user_fixture()
      grant_fixture(pet, pet_owner(pet), writer, "co_caretaker")

      assert Avatars.set_avatar("pet", pet.id, writer, staged_png()) == {:error, :unauthorized}
      assert Avatars.get_avatar("pet", pet.id) == nil
    end

    test "applies a client crop in the purify step", %{owner: owner} do
      # Left square of a 40x20 upload: x=0,y=0,w=0.5,h=1.0 → a 20x20 stored object.
      crop = %{"x" => "0.0", "y" => "0.0", "w" => "0.5", "h" => "1.0"}
      {:ok, _} = Avatars.set_avatar("user", owner.id, owner, staged_png("40x20"), crop)
      Oban.drain_queue(queue: :default)

      assert Avatars.get_avatar("user", owner.id).status == "ready"
      assert object_dims("user", owner.id) == {20, 20}
    end

    test "an invalid crop is dropped — full frame stored", %{owner: owner} do
      # Negative offset is rejected by sanitize_crop ⇒ nil ⇒ no crop ⇒ the whole 40x20 frame.
      crop = %{"x" => "-1.0", "y" => "0.0", "w" => "0.5", "h" => "0.5"}
      {:ok, _} = Avatars.set_avatar("user", owner.id, owner, staged_png("40x20"), crop)
      Oban.drain_queue(queue: :default)

      assert object_dims("user", owner.id) == {40, 20}
    end

    test "a replacement reprocesses the one row", %{owner: owner} do
      {:ok, first} = Avatars.set_avatar("user", owner.id, owner, staged_png())
      Oban.drain_queue(queue: :default)

      {:ok, second} = Avatars.set_avatar("user", owner.id, owner, staged_png())
      assert second.id == first.id
      Oban.drain_queue(queue: :default)

      assert Avatars.get_avatar("user", owner.id).status == "ready"
    end
  end

  describe "failure handling" do
    test "a bad file drops the first-ever row and notifies the uploader", %{owner: owner} do
      bad = Path.join(System.tmp_dir!(), "gm_bad_#{System.unique_integer([:positive])}.png")
      File.write!(bad, "not really a png")
      on_exit(fn -> File.rm(bad) end)
      {:ok, token} = Media.stage_upload(bad)

      {:ok, _} = Avatars.set_avatar("user", owner.id, owner, token)
      Oban.drain_queue(queue: :default)

      assert Avatars.get_avatar("user", owner.id) == nil
      refute File.exists?(Storage.staged_path(token))

      assert Enum.any?(
               Goodmao2.Notifications.list_notifications(owner),
               &(&1.type == "avatar_failed")
             )
    end

    test "a video is rejected (avatars are images only)", %{owner: owner} do
      path = Path.join(System.tmp_dir!(), "gm_v_#{System.unique_integer([:positive])}.mp4")

      {_, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-hide_banner -v error -f lavfi -i testsrc=d=1:s=32x32:r=5 -c:v libx264 -pix_fmt yuv420p -t 1 -y) ++
            [path]
        )

      on_exit(fn -> File.rm(path) end)
      {:ok, token} = Media.stage_upload(path)

      {:ok, _} = Avatars.set_avatar("user", owner.id, owner, token)
      Oban.drain_queue(queue: :default)

      assert Avatars.get_avatar("user", owner.id) == nil

      assert Enum.any?(
               Goodmao2.Notifications.list_notifications(owner),
               &(&1.type == "avatar_failed")
             )
    end
  end

  describe "fetch_avatar_object_for_user/3 (existence-hidden)" do
    test "a user avatar is visible to any authenticated user", %{owner: owner} do
      {:ok, _} = Avatars.set_avatar("user", owner.id, owner, staged_png())
      Oban.drain_queue(queue: :default)

      viewer = user_fixture()

      assert {:ok, {"image/png", path}} =
               Avatars.fetch_avatar_object_for_user("user", owner.id, viewer)

      assert File.exists?(path)
    end

    test "a pet avatar requires :read; others are existence-hidden", %{owner: owner, pet: pet} do
      {:ok, _} = Avatars.set_avatar("pet", pet.id, owner, staged_png())
      Oban.drain_queue(queue: :default)

      reader = user_fixture()
      grant_fixture(pet, owner, reader, "viewer")
      stranger = user_fixture()

      assert {:ok, {"image/png", _}} = Avatars.fetch_avatar_object_for_user("pet", pet.id, reader)
      assert Avatars.fetch_avatar_object_for_user("pet", pet.id, stranger) == {:error, :not_found}
    end

    test "a processing avatar has no servable object yet", %{owner: owner} do
      {:ok, _} = Avatars.set_avatar("user", owner.id, owner, staged_png())
      # Not drained — still processing, no bytes on disk.
      assert Avatars.fetch_avatar_object_for_user("user", owner.id, owner) == {:error, :not_found}
    end
  end

  describe "delete_avatar/3" do
    test "removes the row and bytes", %{owner: owner} do
      {:ok, _} = Avatars.set_avatar("user", owner.id, owner, staged_png())
      Oban.drain_queue(queue: :default)
      assert Storage.avatar_exists?("user-#{owner.id}")

      assert :ok = Avatars.delete_avatar("user", owner.id, owner)
      assert Avatars.get_avatar("user", owner.id) == nil
      refute Storage.avatar_exists?("user-#{owner.id}")
    end
  end

  # The pet fixture's owner is its creator; re-fetch them for grant helpers.
  defp pet_owner(pet) do
    Goodmao2.Repo.get!(Goodmao2.Accounts.User, pet.created_by_user_id)
  end
end
