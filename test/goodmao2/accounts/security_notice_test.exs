defmodule Goodmao2.Accounts.SecurityNoticeTest do
  # Audit 2026-11-15: a hijacked session could change an account's password, address, or
  # second factor without the owner ever hearing of it.
  use Goodmao2.DataCase, async: true
  use Oban.Testing, repo: Goodmao2.Repo

  import Goodmao2.AccountsFixtures

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.{SecurityNoticeWorker, TwoFactor}

  defp notice_for(user_id, event),
    do:
      assert_enqueued(
        worker: SecurityNoticeWorker,
        args: %{"user_id" => user_id, "event" => event}
      )

  test "a password change is told to the account" do
    user = set_password(user_fixture())

    {:ok, _} =
      Accounts.update_user_password(user, valid_user_password(), %{password: "a new password 42!"})

    notice_for(user.id, "password_changed")
  end

  test "an email change is told to the address it replaced, not the new one" do
    user = user_fixture()
    old = user.email
    new = unique_user_email()

    token =
      extract_user_token(fn url ->
        Accounts.deliver_user_update_email_instructions(%{user | email: new}, old, url)
      end)

    {:ok, _} = Accounts.update_user_email(user, token)

    assert_enqueued(
      worker: SecurityNoticeWorker,
      args: %{"user_id" => user.id, "event" => "email_changed", "to" => old}
    )
  end

  test "second-factor changes are told to the account" do
    user = user_fixture()

    {:ok, user} = TwoFactor.enable_totp(user, TwoFactor.generate_totp_secret())
    notice_for(user.id, "totp_enabled")

    [code | _] = TwoFactor.generate_recovery_codes(user)
    notice_for(user.id, "recovery_codes_generated")

    :ok = TwoFactor.verify_recovery_code(user, code)
    notice_for(user.id, "recovery_code_used")

    {:ok, _} = TwoFactor.disable_totp(user)
    notice_for(user.id, "totp_disabled")
  end

  test "adding and removing a security key are told to the account" do
    user = user_fixture()

    {:ok, credential} =
      Accounts.create_webauthn_credential(user, %{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key_cbor: CBOR.encode(%{1 => 2, -2 => :crypto.strong_rand_bytes(32)}),
        sign_count: 0,
        label: "Key"
      })

    notice_for(user.id, "security_key_added")

    {:ok, _} = Accounts.delete_webauthn_credential(user, credential.id)
    notice_for(user.id, "security_key_removed")
  end

  test "the worker mails the notice, without a link, to the address it is given" do
    user = user_fixture()
    elsewhere = unique_user_email()

    assert :ok =
             perform_job(SecurityNoticeWorker, %{
               "user_id" => user.id,
               "event" => "email_changed",
               "to" => elsewhere
             })

    assert_received {:email, %Swoosh.Email{to: [{"", ^elsewhere}], text_body: body}}
    assert body =~ "email address on your account was changed"
    refute body =~ "http"
  end

  test "an unknown event or a deleted account sends nothing" do
    user = user_fixture()

    assert :ok = perform_job(SecurityNoticeWorker, %{"user_id" => user.id, "event" => "bogus"})
    assert :ok = perform_job(SecurityNoticeWorker, %{"user_id" => -1, "event" => "totp_enabled"})

    refute_received {:email, %Swoosh.Email{subject: "Security notice" <> _}}
  end
end
