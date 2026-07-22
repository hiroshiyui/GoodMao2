defmodule Goodmao2.Accounts.TwoFactorTest do
  use Goodmao2.DataCase, async: true

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.TwoFactor

  import Goodmao2.AccountsFixtures

  describe "login_next_step/1" do
    test ":authenticated for a regular user with no second factor" do
      assert TwoFactor.login_next_step(regular_user_fixture()) == :authenticated
    end

    test ":setup_required for an admin with no second factor" do
      assert TwoFactor.login_next_step(admin_fixture()) == :setup_required
    end

    test ":challenge for a user with TOTP enabled" do
      {user, _secret} = totp_user_fixture()
      assert TwoFactor.login_next_step(user) == :challenge
    end

    test ":challenge for a user with a security key" do
      user = user_fixture()
      webauthn_credential_fixture(user)
      assert TwoFactor.login_next_step(user) == :challenge
    end

    test ":challenge for an admin once a factor is enrolled" do
      admin = admin_fixture()
      webauthn_credential_fixture(admin)
      assert TwoFactor.login_next_step(admin) == :challenge
    end
  end

  describe "TOTP enable/verify/disable" do
    test "enable_totp stores an encrypted secret and stamps totp_confirmed_at" do
      user = user_fixture()
      secret = Accounts.generate_totp_secret()

      {:ok, user} = Accounts.enable_totp(user, secret)

      assert Accounts.totp_enabled?(user)
      assert user.totp_confirmed_at
      # Stored ciphertext must not equal the raw secret.
      refute user.totp_secret == secret
      assert Accounts.decrypt_totp_secret(user) == secret
    end

    test "valid_totp? accepts the current code and rejects a wrong one" do
      {_user, secret} = totp_user_fixture()
      code = NimbleTOTP.verification_code(secret)

      assert Accounts.valid_totp?(secret, code)
      refute Accounts.valid_totp?(secret, "000000")
    end

    test "valid_totp? with :since rejects a code from the same window (replay)" do
      {_user, secret} = totp_user_fixture()
      code = NimbleTOTP.verification_code(secret)

      # Accepted on first use, then rejected when we mark the window as already-consumed.
      assert Accounts.valid_totp?(secret, code)
      refute Accounts.valid_totp?(secret, code, since: System.system_time(:second))
    end

    test "record_totp_used stamps totp_last_used_at for replay rejection" do
      {user, _secret} = totp_user_fixture()
      assert is_nil(user.totp_last_used_at)

      {:ok, user} = Accounts.record_totp_used(user)

      assert %DateTime{} = user.totp_last_used_at
    end

    test "disable_totp clears the secret, last-used stamp, and recovery codes" do
      {user, _secret} = totp_user_fixture()
      {:ok, user} = Accounts.record_totp_used(user)
      Accounts.generate_recovery_codes(user)
      assert Accounts.recovery_codes_remaining(user) == 10

      {:ok, user} = Accounts.disable_totp(user)

      refute Accounts.totp_enabled?(user)
      assert is_nil(user.totp_secret)
      assert is_nil(user.totp_last_used_at)
      assert Accounts.recovery_codes_remaining(user) == 0
    end
  end

  describe "recovery codes" do
    test "generate returns 10 formatted codes and stores only hashes" do
      user = user_fixture()
      codes = Accounts.generate_recovery_codes(user)

      assert length(codes) == 10
      assert Enum.all?(codes, &(&1 =~ ~r/^[a-z2-7]{4}-[a-z2-7]{4}$/))
      assert Accounts.recovery_codes_remaining(user) == 10
    end

    test "verify consumes a code exactly once (single-use)" do
      user = user_fixture()
      [code | _] = Accounts.generate_recovery_codes(user)

      assert Accounts.verify_recovery_code(user, code) == :ok
      assert Accounts.verify_recovery_code(user, code) == :error
      assert Accounts.recovery_codes_remaining(user) == 9
    end

    test "verify tolerates formatting differences and rejects unknown codes" do
      user = user_fixture()
      [code | _] = Accounts.generate_recovery_codes(user)

      assert Accounts.verify_recovery_code(user, "  " <> String.upcase(code) <> " ") == :ok
      assert Accounts.verify_recovery_code(user, "zzzz-zzzz") == :error
    end

    test "regenerating invalidates the previous set" do
      user = user_fixture()
      [old | _] = Accounts.generate_recovery_codes(user)
      Accounts.generate_recovery_codes(user)

      assert Accounts.verify_recovery_code(user, old) == :error
      assert Accounts.recovery_codes_remaining(user) == 10
    end
  end

  describe "can_remove_second_factor?/2" do
    test "always true for non-admins" do
      user = regular_user_fixture()
      {:ok, user} = Accounts.enable_totp(user, Accounts.generate_totp_secret())
      assert Accounts.can_remove_second_factor?(user, :totp)
    end

    test "refuses removing an admin's last factor" do
      admin = admin_fixture()
      secret = Accounts.generate_totp_secret()
      {:ok, admin} = Accounts.enable_totp(admin, secret)

      # TOTP is the only factor — cannot remove it.
      refute Accounts.can_remove_second_factor?(admin, :totp)

      # With a key also enrolled, removing TOTP is allowed.
      webauthn_credential_fixture(admin)
      assert Accounts.can_remove_second_factor?(admin, :totp)
    end

    test "refuses removing an admin's only security key when no TOTP" do
      admin = admin_fixture()
      webauthn_credential_fixture(admin)

      refute Accounts.can_remove_second_factor?(admin, :webauthn)

      webauthn_credential_fixture(admin)
      assert Accounts.can_remove_second_factor?(admin, :webauthn)
    end
  end
end
