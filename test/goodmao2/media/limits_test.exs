defmodule Goodmao2.Media.LimitsTest do
  use Goodmao2.DataCase, async: true

  alias Goodmao2.Media.Limits
  alias Goodmao2.Settings

  describe "get/1" do
    test "falls back to the configured default when the setting is unset" do
      # config/config.exs ships these defaults (test.exs relaxes only the image min dimensions).
      assert Limits.get(:max_image_bytes) == 8_000_000
      assert Limits.get(:max_video_bytes) == 16_000_000
    end

    test "a Settings value overrides the default" do
      Settings.put("media_max_image_bytes", "1234")
      assert Limits.get(:max_image_bytes) == 1234
    end

    test "0 is a valid override (lifts the bound)" do
      Settings.put("media_max_image_width", "0")
      assert Limits.get(:max_image_width) == 0
    end

    test "a blank or non-integer stored value is ignored in favour of the default" do
      Settings.put("media_max_video_bytes", "  ")
      assert Limits.get(:max_video_bytes) == 16_000_000

      Settings.put("media_max_video_bytes", "not-a-number")
      assert Limits.get(:max_video_bytes) == 16_000_000

      Settings.put("media_max_video_bytes", "-5")
      assert Limits.get(:max_video_bytes) == 16_000_000
    end
  end

  describe "fields/0 and setting_key/1" do
    test "every field maps to a `media_`-namespaced settings key" do
      assert :max_image_bytes in Limits.fields()
      assert Limits.setting_key(:max_image_bytes) == "media_max_image_bytes"
      assert Limits.setting_key(:min_video_height) == "media_min_video_height"
    end
  end
end
