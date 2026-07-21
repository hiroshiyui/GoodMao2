defmodule Goodmao2.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Goodmao2.Accounts` context.
  """

  import Ecto.Query

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email()
    })
  end

  def unconfirmed_user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_fixture(attrs \\ %{}) do
    user = unconfirmed_user_fixture(attrs)

    token =
      extract_user_token(fn url ->
        Accounts.deliver_login_instructions(user, url)
      end)

    {:ok, {user, _expired_tokens}} =
      Accounts.login_user_by_magic_link(token)

    user
  end

  def admin_fixture(attrs \\ %{}) do
    Goodmao2.Repo.update!(Accounts.User.admin_changeset(user_fixture(attrs)))
  end

  def valid_vet_profile_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "license_number" => "VET-#{System.unique_integer([:positive])}",
      "licensing_body" => "State Veterinary Board",
      "region" => "Taiwan",
      "clinic_name" => "Kindly Paws Clinic"
    })
  end

  @doc "Creates a `pending` vet profile for `user`."
  def vet_profile_fixture(user, attrs \\ %{}) do
    {:ok, profile} = Accounts.submit_vet_profile(user, valid_vet_profile_attributes(attrs))
    profile
  end

  @doc "Creates a **verified** vet profile for `user` (so they may be granted the vet role)."
  def verified_vet_profile_fixture(user, attrs \\ %{}) do
    profile = vet_profile_fixture(user, attrs)
    {:ok, verified} = Accounts.verify_vet_profile(admin_fixture(), profile)
    verified
  end

  @doc """
  Creates a confirmed **non-admin** user.

  The first-ever registered account becomes the sole admin, so this ensures another
  account already exists (creating the admin seat if needed) before registering.
  """
  def regular_user_fixture(attrs \\ %{}) do
    unless Accounts.count_users() > 0, do: admin_fixture()
    user_fixture(attrs)
  end

  @doc """
  Creates a user with TOTP enabled and returns `{user, raw_secret}` so the test can
  generate valid codes with `NimbleTOTP.verification_code/1`.
  """
  def totp_user_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)
    secret = Accounts.generate_totp_secret()
    {:ok, user} = Accounts.enable_totp(user, secret)
    {user, secret}
  end

  @doc """
  Inserts a WebAuthn credential row for `user` directly (bypassing the ceremony). Enough
  to exercise `webauthn_enabled?`, `login_next_step`, listing, and deletion.
  """
  def webauthn_credential_fixture(user, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        credential_id: :crypto.strong_rand_bytes(32),
        public_key_cbor: :crypto.strong_rand_bytes(64),
        sign_count: 0,
        label: "Test key"
      })

    {:ok, credential} = Accounts.create_webauthn_credential(user, attrs)
    credential
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Goodmao2.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Goodmao2.Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Goodmao2.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
