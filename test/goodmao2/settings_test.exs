defmodule Goodmao2.SettingsTest do
  use Goodmao2.DataCase, async: true

  alias Goodmao2.Settings

  describe "get/1 and put/2" do
    test "get returns nil for an unset key" do
      assert Settings.get("nope") == nil
    end

    test "put stores a value that get reads back" do
      assert {:ok, _} = Settings.put("vapid_subject", "mailto:vet@example.com")
      assert Settings.get("vapid_subject") == "mailto:vet@example.com"
    end

    test "put upserts an existing key rather than duplicating it" do
      {:ok, _} = Settings.put("k", "one")
      {:ok, _} = Settings.put("k", "two")

      assert Settings.get("k") == "two"
      assert Repo.aggregate(from(s in Settings.Setting, where: s.key == "k"), :count) == 1
    end
  end
end
