defmodule Goodmao2Web.HelpersTest do
  use ExUnit.Case, async: true

  import Goodmao2Web.Helpers
  alias Goodmao2.Timezone

  describe "format_datetime/1,2 (timezone-aware)" do
    test "shifts a UTC datetime into an explicit zone" do
      dt = ~U[2026-07-21 00:30:00Z]
      assert format_datetime(dt, "Asia/Taipei") == "2026-07-21 08:30"
      assert format_datetime(dt, "Etc/UTC") == "2026-07-21 00:30"
    end

    test "uses the process active timezone for /1" do
      dt = ~U[2026-07-21 00:30:00Z]
      Timezone.put_current("Asia/Taipei")
      assert format_datetime(dt) == "2026-07-21 08:30"
      Timezone.put_current("Etc/UTC")
      assert format_datetime(dt) == "2026-07-21 00:30"
    end

    test "nil renders empty" do
      assert format_datetime(nil) == ""
      assert format_datetime(nil, "Asia/Taipei") == ""
    end
  end

  describe "format_date/1,2 (timezone-aware)" do
    test "shifts a UTC datetime's date into the zone (can cross midnight)" do
      # 23:30 UTC is already the next day in Taipei (+8).
      dt = ~U[2026-07-21 23:30:00Z]
      assert format_date(dt, "Asia/Taipei") == "2026-07-22"
      assert format_date(dt, "Etc/UTC") == "2026-07-21"
    end

    test "a plain Date is zoneless and formatted as-is" do
      assert format_date(~D[2026-07-21], "Asia/Taipei") == "2026-07-21"
    end

    test "nil renders empty" do
      assert format_date(nil) == ""
    end
  end
end
