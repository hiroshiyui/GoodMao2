defmodule Goodmao2.Notifications.WebPushTest do
  use Goodmao2.DataCase, async: true

  import Goodmao2.AccountsFixtures

  alias Goodmao2.Notifications.PushSubscription
  alias Goodmao2.Notifications.WebPush
  alias Goodmao2.Notifications.WebPush.SafeClient
  alias Goodmao2.Settings

  # A browser subscriber keypair (p256dh public + auth secret).
  defp subscriber do
    {p256dh, private} = :crypto.generate_key(:ecdh, :prime256v1)
    %{p256dh: p256dh, private: private, auth: :crypto.strong_rand_bytes(16)}
  end

  defp configure_vapid do
    {public_key, encrypted_private} = WebPush.generate_keypair()
    {:ok, _} = Settings.put("vapid_public_key", public_key)
    {:ok, _} = Settings.put("vapid_private_key_encrypted", Base.encode64(encrypted_private))
  end

  defp insert_subscription(sub) do
    {:ok, subscription} =
      %PushSubscription{}
      |> PushSubscription.changeset(%{
        endpoint: "https://push.example.com/#{System.unique_integer([:positive])}",
        p256dh: sub.p256dh,
        auth: sub.auth,
        user_id: user_fixture().id
      })
      |> Repo.insert()

    subscription
  end

  describe "encrypt/3 (RFC 8291 aes128gcm)" do
    test "produces a well-formed wire frame that the subscriber can decrypt" do
      sub = subscriber()
      plaintext = ~s({"title":"New log entry"})

      frame = WebPush.encrypt(plaintext, sub.p256dh, sub.auth)

      # salt(16) || rs(4) || idlen(1) || server_public(idlen) || ciphertext || tag(16)
      <<salt::binary-16, rs::unsigned-big-32, idlen, rest::binary>> = frame
      assert rs == 4096
      assert idlen == 65
      <<server_public::binary-size(idlen), body::binary>> = rest

      assert decrypt(body, salt, server_public, sub) == plaintext
    end
  end

  describe "vapid_configured?/0 and generate_keypair/0" do
    test "is false until keys are stored, then true" do
      refute WebPush.vapid_configured?()
      configure_vapid()
      assert WebPush.vapid_configured?()
      assert is_binary(WebPush.public_key())
    end
  end

  describe "send_web_push/2" do
    setup do
      configure_vapid()
      :ok
    end

    test "returns :ok on a 2xx response" do
      subscription = insert_subscription(subscriber())
      Req.Test.stub(SafeClient, fn conn -> Plug.Conn.send_resp(conn, 201, "") end)

      assert WebPush.send_web_push(subscription, ~s({"title":"hi"})) == :ok
    end

    test "soft-deletes the subscription and returns {:error, :gone} on 410" do
      subscription = insert_subscription(subscriber())
      Req.Test.stub(SafeClient, fn conn -> Plug.Conn.send_resp(conn, 410, "") end)

      assert WebPush.send_web_push(subscription, ~s({"title":"hi"})) == {:error, :gone}
      assert Repo.get(PushSubscription, subscription.id).deleted_at
    end

    test "returns an error on a 5xx (subscription kept)" do
      subscription = insert_subscription(subscriber())
      Req.Test.stub(SafeClient, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, {:http_error, 500}} = WebPush.send_web_push(subscription, ~s({"a":1}))
      refute Repo.get(PushSubscription, subscription.id).deleted_at
    end
  end

  # RFC 8291 decryption, re-implemented from the subscriber's side to verify encrypt/3.
  defp decrypt(body, salt, server_public, sub) do
    shared = :crypto.compute_key(:ecdh, server_public, sub.private, :prime256v1)
    auth_info = "WebPush: info\0" <> sub.p256dh <> server_public
    ikm = hkdf(sub.auth, shared, auth_info, 32)
    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm\0", 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce\0", 12)

    ct_size = byte_size(body) - 16
    <<ciphertext::binary-size(ct_size), tag::binary-16>> = body
    padded = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, "", tag, false)
    binary_part(padded, 0, byte_size(padded) - 1)
  end

  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    binary_part(:crypto.mac(:hmac, :sha256, prk, info <> <<1>>), 0, length)
  end
end
