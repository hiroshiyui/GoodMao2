defmodule Goodmao2.Accounts.TotpVaultTest do
  use ExUnit.Case, async: true

  alias Goodmao2.Accounts.TotpVault

  test "round-trips a TOTP secret through encrypt/decrypt" do
    secret = NimbleTOTP.secret()
    assert {:ok, ^secret} = TotpVault.decrypt(TotpVault.encrypt(secret))
  end

  test "produces a fresh IV each time (ciphertexts differ)" do
    secret = NimbleTOTP.secret()
    refute TotpVault.encrypt(secret) == TotpVault.encrypt(secret)
  end

  test "rejects a tampered ciphertext" do
    <<iv::binary-12, tag::binary-16, ct::binary>> = TotpVault.encrypt("secret")
    flipped = :crypto.exor(ct, :binary.copy(<<1>>, byte_size(ct)))
    assert TotpVault.decrypt(iv <> tag <> flipped) == :error
  end

  test "rejects a corrupted IV/tag" do
    <<_iv::binary-12, tag::binary-16, ct::binary>> = TotpVault.encrypt("secret")
    assert TotpVault.decrypt(:crypto.strong_rand_bytes(12) <> tag <> ct) == :error
  end

  test "rejects a malformed blob" do
    assert TotpVault.decrypt("too short") == :error
    assert TotpVault.decrypt(<<>>) == :error
  end
end
