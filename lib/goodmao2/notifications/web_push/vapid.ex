defmodule Goodmao2.Notifications.WebPush.Vapid do
  @moduledoc """
  VAPID (RFC 8292) ES256 JWT signing for Web Push authentication.

  Produces the `Authorization: vapid t=<jwt>, k=<public_key>` header a push service requires.
  The JWT is signed with ECDSA P-256 + SHA-256; `:crypto.sign/4` emits a DER signature, but
  VAPID requires raw `r‖s` (64 bytes), so `der_to_raw_p256/1` converts it — a small,
  load-bearing step.

  Key formats: public key = 65-byte uncompressed EC point (base64url, no padding); private
  key = 32-byte raw scalar (already decrypted by the caller).
  """

  @jwt_lifetime 12 * 3600

  @doc """
  Signs an ES256 VAPID JWT.

  - `audience` — the push service origin, e.g. `"https://fcm.googleapis.com"`
  - `private_key` — the raw 32-byte ECDSA private scalar (decrypted)
  - `subject` — the VAPID contact, e.g. `"mailto:admin@example.com"`
  """
  def sign_jwt(audience, private_key, subject)
      when is_binary(audience) and is_binary(private_key) and is_binary(subject) do
    header = Base.url_encode64(Jason.encode!(%{"typ" => "JWT", "alg" => "ES256"}), padding: false)

    claims =
      Base.url_encode64(
        Jason.encode!(%{
          "aud" => audience,
          "exp" => System.system_time(:second) + @jwt_lifetime,
          "sub" => subject
        }),
        padding: false
      )

    signing_input = header <> "." <> claims

    der_signature = :crypto.sign(:ecdsa, :sha256, signing_input, [private_key, :prime256v1])
    {:ok, raw_signature} = der_to_raw_p256(der_signature)

    signature = Base.url_encode64(raw_signature, padding: false)

    signing_input <> "." <> signature
  end

  @doc """
  Builds the VAPID request headers for a push to `endpoint`.

  The audience is derived from the endpoint's scheme + host (default ports normalized away).
  """
  def authorization_headers(endpoint, public_key_b64, private_key, subject) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)

    audience =
      case {scheme, port} do
        {"https", 443} -> "#{scheme}://#{host}"
        {"https", nil} -> "#{scheme}://#{host}"
        {"http", 80} -> "#{scheme}://#{host}"
        {"http", nil} -> "#{scheme}://#{host}"
        _ -> "#{scheme}://#{host}:#{port}"
      end

    jwt = sign_jwt(audience, private_key, subject)

    [
      {"authorization", "vapid t=#{jwt}, k=#{public_key_b64}"},
      {"ttl", "86400"}
    ]
  end

  # DER-encoded ECDSA signature → raw r‖s (64 bytes).
  # DER: 0x30 <len> 0x02 <r_len> <r_bytes> 0x02 <s_len> <s_bytes>. Each of r/s must become
  # exactly 32 bytes (left-padded with zeros, or a leading zero byte trimmed).
  @doc false
  def der_to_raw_p256(der) do
    case der do
      <<0x30, _total_len, 0x02, r_len, r_bytes::binary-size(r_len), 0x02, s_len,
        s_bytes::binary-size(s_len)>>
      when r_len in 1..33 and s_len in 1..33 ->
        {:ok, pad_or_trim_to_32(r_bytes) <> pad_or_trim_to_32(s_bytes)}

      _ ->
        {:error, :invalid_der}
    end
  end

  defp pad_or_trim_to_32(bytes) when byte_size(bytes) == 32, do: bytes

  defp pad_or_trim_to_32(bytes) when byte_size(bytes) < 32 do
    :binary.copy(<<0>>, 32 - byte_size(bytes)) <> bytes
  end

  defp pad_or_trim_to_32(bytes) when byte_size(bytes) > 32 do
    trimmed = trim_leading_zeros(bytes, byte_size(bytes) - 32)

    if byte_size(trimmed) > 32 do
      binary_part(trimmed, byte_size(trimmed) - 32, 32)
    else
      trimmed
    end
  end

  defp trim_leading_zeros(<<0, rest::binary>>, n) when n > 0, do: trim_leading_zeros(rest, n - 1)
  defp trim_leading_zeros(bytes, _), do: bytes
end
