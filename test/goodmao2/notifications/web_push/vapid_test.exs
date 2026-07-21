defmodule Goodmao2.Notifications.WebPush.VapidTest do
  use ExUnit.Case, async: true

  alias Goodmao2.Notifications.WebPush.Vapid

  defp keypair, do: :crypto.generate_key(:ecdh, :prime256v1)

  describe "der_to_raw_p256/1" do
    test "converts any real ECDSA signature to a 64-byte r‖s" do
      {_pub, priv} = keypair()

      for i <- 1..50 do
        der = :crypto.sign(:ecdsa, :sha256, "message #{i}", [priv, :prime256v1])
        assert {:ok, raw} = Vapid.der_to_raw_p256(der)
        assert byte_size(raw) == 64
      end
    end

    test "rejects a non-DER blob" do
      assert Vapid.der_to_raw_p256(<<0, 1, 2, 3>>) == {:error, :invalid_der}
    end
  end

  describe "sign_jwt/3" do
    test "produces a verifiable ES256 JWT with the expected header and claims" do
      {pub, priv} = keypair()

      jwt = Vapid.sign_jwt("https://push.example.com", priv, "mailto:admin@example.com")

      assert [header_b64, claims_b64, sig_b64] = String.split(jwt, ".")

      assert %{"typ" => "JWT", "alg" => "ES256"} =
               header_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()

      claims = claims_b64 |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert claims["aud"] == "https://push.example.com"
      assert claims["sub"] == "mailto:admin@example.com"
      assert is_integer(claims["exp"])

      # The signature verifies against the public key (raw r‖s → DER for :crypto.verify).
      raw = Base.url_decode64!(sig_b64, padding: false)
      assert byte_size(raw) == 64
      <<r::binary-32, s::binary-32>> = raw
      der = raw_to_der(r, s)

      assert :crypto.verify(:ecdsa, :sha256, header_b64 <> "." <> claims_b64, der, [
               pub,
               :prime256v1
             ])
    end
  end

  describe "authorization_headers/4" do
    test "normalizes the default port out of the audience and sets the vapid header + ttl" do
      {pub, priv} = keypair()
      pub_b64 = Base.url_encode64(pub, padding: false)

      headers =
        Vapid.authorization_headers(
          "https://push.example.com:443/xyz",
          pub_b64,
          priv,
          "mailto:a@b.com"
        )

      assert {"ttl", "86400"} in headers
      assert {_, "vapid t=" <> _rest = auth} = List.keyfind(headers, "authorization", 0)
      assert auth =~ "k=#{pub_b64}"
    end
  end

  # Encodes r and s as an ASN.1 DER ECDSA signature (minimal big-endian, 0x00 prefix when
  # the high bit is set) so :crypto.verify can check the raw signature sign_jwt emits.
  defp raw_to_der(r, s),
    do: <<0x30, byte_size(der_int(r) <> der_int(s))>> <> der_int(r) <> der_int(s)

  defp der_int(bytes) do
    trimmed = trim(bytes)
    trimmed = if :binary.first(trimmed) >= 0x80, do: <<0>> <> trimmed, else: trimmed
    <<0x02, byte_size(trimmed)>> <> trimmed
  end

  defp trim(<<0, rest::binary>>) when byte_size(rest) > 0, do: trim(rest)
  defp trim(bytes), do: bytes
end
