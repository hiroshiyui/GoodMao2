defmodule Goodmao2.Notifications.WebPush.VapidVaultTest do
  use ExUnit.Case, async: true

  alias Goodmao2.Notifications.WebPush.VapidVault

  test "round-trips a private key through encrypt/decrypt" do
    secret = :crypto.strong_rand_bytes(32)
    assert {:ok, ^secret} = VapidVault.decrypt(VapidVault.encrypt(secret))
  end

  test "produces a fresh IV each time (ciphertexts differ)" do
    secret = :crypto.strong_rand_bytes(32)
    refute VapidVault.encrypt(secret) == VapidVault.encrypt(secret)
  end

  test "rejects a tampered ciphertext" do
    <<iv::binary-12, tag::binary-16, ct::binary>> = VapidVault.encrypt("secret")
    flipped = :crypto.exor(ct, :binary.copy(<<1>>, byte_size(ct)))
    assert VapidVault.decrypt(iv <> tag <> flipped) == :error
  end

  test "rejects a malformed blob" do
    assert VapidVault.decrypt("too short") == :error
    assert VapidVault.decrypt(<<>>) == :error
  end
end
