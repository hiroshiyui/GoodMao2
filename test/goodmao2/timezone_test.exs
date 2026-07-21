defmodule Goodmao2.TimezoneTest do
  # async: false — system_default/resolve touch the app-global Settings ETS cache.
  use Goodmao2.DataCase, async: false

  alias Goodmao2.Timezone
  alias Goodmao2.Accounts.{Scope, User}

  describe "all/0" do
    test "is a sorted, unique list of canonical zones including Etc/UTC" do
      zones = Timezone.all()
      assert "Asia/Taipei" in zones
      assert "America/New_York" in zones
      assert "Etc/UTC" in zones
      assert zones == Enum.sort(zones)
      assert zones == Enum.uniq(zones)
    end
  end

  describe "known?/1" do
    test "accepts canonical zones and browser aliases, rejects junk" do
      assert Timezone.known?("Asia/Taipei")
      # An alias not present in the canonical picker list still validates (DB-backed).
      assert Timezone.known?("Asia/Chongqing")
      refute Timezone.known?("Not/AZone")
      refute Timezone.known?("")
      refute Timezone.known?(nil)
      refute Timezone.known?(123)
    end
  end

  describe "default/0 and current/0" do
    test "default is the configured fallback" do
      assert Timezone.default() == "Etc/UTC"
    end

    test "current falls back to Etc/UTC and reflects put_current" do
      assert Timezone.current() == "Etc/UTC"
      assert Timezone.put_current("Asia/Tokyo") == "Asia/Tokyo"
      assert Timezone.current() == "Asia/Tokyo"
    end
  end

  describe "system_default/0" do
    test "is the configured default when unset" do
      assert Timezone.system_default() == "Etc/UTC"
    end

    test "reflects a valid admin setting, ignores an invalid one" do
      # The DB row rolls back with the sandbox, but the Settings cache is process-global — reset
      # the cache entry after so the default doesn't leak into other tests.
      on_exit(fn -> Goodmao2.Settings.Cache.put("default_timezone", nil) end)

      Goodmao2.Settings.put("default_timezone", "Asia/Taipei")
      assert Timezone.system_default() == "Asia/Taipei"

      Goodmao2.Settings.put("default_timezone", "Bogus/Zone")
      assert Timezone.system_default() == "Etc/UTC"
    end
  end

  describe "resolve/1" do
    test "user preference wins when valid" do
      assert Timezone.resolve(%User{timezone: "Asia/Taipei"}) == "Asia/Taipei"
      assert Timezone.resolve(%Scope{user: %User{timezone: "Asia/Taipei"}}) == "Asia/Taipei"
    end

    test "invalid or missing preference falls back to system default" do
      assert Timezone.resolve(%User{timezone: "Bogus/Zone"}) == "Etc/UTC"
      assert Timezone.resolve(%User{timezone: nil}) == "Etc/UTC"
      assert Timezone.resolve(nil) == "Etc/UTC"
    end
  end

  describe "to_local/2" do
    test "shifts a UTC datetime into the zone" do
      utc = ~U[2026-07-21 00:30:00Z]
      local = Timezone.to_local(utc, "Asia/Taipei")
      assert local.hour == 8
      assert local.time_zone == "Asia/Taipei"
    end

    test "returns the datetime unchanged on a bad zone" do
      utc = ~U[2026-07-21 00:30:00Z]
      assert Timezone.to_local(utc, "Bogus/Zone") == utc
    end
  end

  describe "local_naive_to_utc/2" do
    test "interprets wall-clock in the zone and returns UTC (no-DST zone)" do
      # 08:30 in Taipei (UTC+8, no DST) is 00:30 UTC.
      assert {:ok, dt} = Timezone.local_naive_to_utc("2026-07-21T08:30", "Asia/Taipei")
      assert dt == ~U[2026-07-21 00:30:00Z]
    end

    test "accepts a value with seconds and a NaiveDateTime" do
      assert {:ok, ~U[2026-07-21 00:30:15Z]} =
               Timezone.local_naive_to_utc("2026-07-21T08:30:15", "Asia/Taipei")

      assert {:ok, ~U[2026-07-21 00:30:00Z]} =
               Timezone.local_naive_to_utc(~N[2026-07-21 08:30:00], "Asia/Taipei")
    end

    test "resolves a spring-forward gap to the just-after instant" do
      # 02:30 on 2026-03-08 does not exist in America/New_York; the transition lands at
      # 03:00 EDT (-04:00) = 07:00 UTC.
      assert {:ok, dt} = Timezone.local_naive_to_utc("2026-03-08T02:30", "America/New_York")
      assert dt == ~U[2026-03-08 07:00:00Z]
    end

    test "resolves an ambiguous fall-back hour to the earlier instant" do
      # 01:30 on 2026-11-01 occurs twice; the earlier is EDT (-04:00) = 05:30 UTC.
      assert {:ok, dt} = Timezone.local_naive_to_utc("2026-11-01T01:30", "America/New_York")
      assert dt == ~U[2026-11-01 05:30:00Z]
    end

    test "returns :error on unparseable input or bad zone" do
      assert Timezone.local_naive_to_utc("not-a-date", "Asia/Taipei") == :error
      assert Timezone.local_naive_to_utc("2026-07-21T08:30", "Bogus/Zone") == :error
    end
  end
end
