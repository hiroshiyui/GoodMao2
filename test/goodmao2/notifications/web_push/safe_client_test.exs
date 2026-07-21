defmodule Goodmao2.Notifications.WebPush.SafeClientTest do
  use ExUnit.Case, async: true

  alias Goodmao2.Notifications.WebPush.SafeClient

  describe "private_ip?/1" do
    test "flags IPv4 private / loopback / link-local / CGNAT / reserved" do
      for ip <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 168, 1, 1},
            {169, 254, 0, 1},
            {0, 0, 0, 0},
            {100, 64, 0, 1},
            {224, 0, 0, 1},
            {255, 255, 255, 255}
          ] do
        assert SafeClient.private_ip?(ip), "expected #{inspect(ip)} to be private"
      end
    end

    test "allows ordinary public IPv4" do
      for ip <- [{8, 8, 8, 8}, {1, 1, 1, 1}, {172, 15, 0, 1}, {172, 32, 0, 1}, {100, 63, 0, 1}] do
        refute SafeClient.private_ip?(ip), "expected #{inspect(ip)} to be public"
      end
    end

    test "flags IPv6 loopback / ULA / link-local / multicast / unspecified" do
      for ip <- [
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 0},
            {0xFC00, 0, 0, 0, 0, 0, 0, 1},
            {0xFD12, 0, 0, 0, 0, 0, 0, 1},
            {0xFE80, 0, 0, 0, 0, 0, 0, 1},
            {0xFF02, 0, 0, 0, 0, 0, 0, 1}
          ] do
        assert SafeClient.private_ip?(ip), "expected #{inspect(ip)} to be private"
      end
    end

    test "unwraps IPv4-mapped IPv6 and re-checks (::ffff:127.0.0.1)" do
      assert SafeClient.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001})
      refute SafeClient.private_ip?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end

    test "unwraps NAT64 IPv6 and re-checks (64:ff9b::127.0.0.1)" do
      assert SafeClient.private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0x7F00, 0x0001})
      refute SafeClient.private_ip?({0x64, 0xFF9B, 0, 0, 0, 0, 0x0808, 0x0808})
    end

    test "allows an ordinary public IPv6" do
      refute SafeClient.private_ip?({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
    end
  end

  describe "validate_url/1" do
    # NOTE: the test env sets bypass_ssrf_check, so DNS/private-IP rejection is not
    # exercised here (it is covered by the private_ip?/1 truth table above). These cases
    # cover the scheme/host guards, which run before resolution.
    test "rejects non-HTTPS and malformed URLs" do
      assert SafeClient.validate_url("ftp://example.com") == {:error, :https_required}
      assert SafeClient.validate_url("https://") == {:error, :invalid_host}
      assert SafeClient.validate_url(nil) == {:error, :invalid_url}
    end

    test "accepts a well-formed HTTPS URL" do
      assert SafeClient.validate_url("https://push.example.com/abc") == :ok
    end
  end
end
