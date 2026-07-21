defmodule Goodmao2.Accounts.WebAuthnTest do
  use Goodmao2.DataCase, async: true

  alias Goodmao2.Accounts

  import Goodmao2.AccountsFixtures

  defp cred_attrs(overrides \\ %{}) do
    Enum.into(overrides, %{
      credential_id: :crypto.strong_rand_bytes(32),
      public_key_cbor: CBOR.encode(%{1 => 2, -2 => :crypto.strong_rand_bytes(32)}),
      sign_count: 0,
      label: "Test key"
    })
  end

  describe "credential CRUD" do
    test "webauthn_enabled? flips true once a credential is enrolled" do
      user = user_fixture()
      refute Accounts.webauthn_enabled?(user)
      {:ok, _} = Accounts.create_webauthn_credential(user, cred_attrs())
      assert Accounts.webauthn_enabled?(user)
    end

    test "list is ordered oldest-first and scoped to the user" do
      user = user_fixture()
      {:ok, c1} = Accounts.create_webauthn_credential(user, cred_attrs(%{label: "one"}))
      {:ok, c2} = Accounts.create_webauthn_credential(user, cred_attrs(%{label: "two"}))

      assert Enum.map(Accounts.list_webauthn_credentials(user), & &1.id) == [c1.id, c2.id]
    end

    test "credential_id is globally unique" do
      user = user_fixture()
      attrs = cred_attrs()
      {:ok, _} = Accounts.create_webauthn_credential(user, attrs)
      assert {:error, changeset} = Accounts.create_webauthn_credential(user, attrs)
      assert %{credential_id: [_]} = errors_on(changeset)
    end

    test "requires credential_id and public_key_cbor" do
      user = user_fixture()
      attrs = Map.drop(cred_attrs(), [:credential_id, :public_key_cbor])
      assert {:error, changeset} = Accounts.create_webauthn_credential(user, attrs)
      errors = errors_on(changeset)
      assert errors[:credential_id]
      assert errors[:public_key_cbor]
    end

    test "delete is owner-scoped and existence-hidden" do
      user = regular_user_fixture()
      other = user_fixture()
      {:ok, cred} = Accounts.create_webauthn_credential(other, cred_attrs())

      # Another user cannot delete it — indistinguishable from a missing id.
      assert {:error, :not_found} = Accounts.delete_webauthn_credential(user, cred.id)
      assert {:error, :not_found} = Accounts.delete_webauthn_credential(user, 0)

      # The owner can.
      assert {:ok, _} = Accounts.delete_webauthn_credential(other, cred.id)
      assert [] == Accounts.list_webauthn_credentials(other)
    end
  end

  describe "begin_registration/1" do
    test "returns a token and creation options, storing an attestation challenge in ETS" do
      user = user_fixture()
      {token, json} = Accounts.begin_webauthn_registration(user)

      assert is_binary(token) and byte_size(token) > 0
      options = Jason.decode!(json)
      assert is_binary(options["challenge"])
      assert options["rp"]["id"] == "localhost"
      assert options["attestation"] == "none"
      assert is_list(options["pubKeyCredParams"])
      # Request a discoverable credential so passkey managers (Bitwarden, etc.) are offered.
      assert options["authenticatorSelection"]["residentKey"] == "preferred"

      assert {:ok, %Wax.Challenge{type: :attestation}} =
               Goodmao2.Accounts.WebAuthnChallenges.pop(token, user.id)
    end

    test "excludeCredentials lists already-enrolled keys" do
      user = user_fixture()
      {:ok, cred} = Accounts.create_webauthn_credential(user, cred_attrs())
      {_token, json} = Accounts.begin_webauthn_registration(user)

      ids = Jason.decode!(json)["excludeCredentials"] |> Enum.map(& &1["id"])
      assert Base.url_encode64(cred.credential_id, padding: false) in ids
    end
  end

  describe "begin_authentication/1" do
    test "lists enrolled credentials in allowCredentials and stores an auth challenge" do
      user = user_fixture()
      {:ok, cred} = Accounts.create_webauthn_credential(user, cred_attrs())
      {token, json} = Accounts.begin_webauthn_authentication(user)

      options = Jason.decode!(json)
      assert options["rpId"] == "localhost"
      ids = Enum.map(options["allowCredentials"], & &1["id"])
      assert Base.url_encode64(cred.credential_id, padding: false) in ids

      assert {:ok, %Wax.Challenge{type: :authentication}} =
               Goodmao2.Accounts.WebAuthnChallenges.pop(token, user.id)
    end

    test "allowCredentials is empty with no keys" do
      user = user_fixture()
      {_token, json} = Accounts.begin_webauthn_authentication(user)
      assert Jason.decode!(json)["allowCredentials"] == []
    end
  end

  describe "finish_* error paths" do
    test "finish_registration rejects invalid base64" do
      user = user_fixture()

      challenge =
        Wax.new_registration_challenge(origin: "https://localhost:4001", rp_id: "localhost")

      assert {:error, :invalid_base64} =
               Accounts.finish_webauthn_registration(user, "not!!b64", "dGVzdA", challenge)
    end

    test "finish_authentication returns :unknown_credential for a credential not owned" do
      user = regular_user_fixture()
      other = user_fixture()
      {:ok, cred} = Accounts.create_webauthn_credential(other, cred_attrs())

      challenge =
        Wax.new_authentication_challenge(origin: "https://localhost:4001", rp_id: "localhost")

      cid = Base.url_encode64(cred.credential_id, padding: false)
      b = Base.url_encode64("x", padding: false)

      assert {:error, :unknown_credential} =
               Accounts.finish_webauthn_authentication(user, cid, b, b, b, challenge)
    end

    test "finish_authentication rejects invalid base64 credential_id" do
      user = user_fixture()

      challenge =
        Wax.new_authentication_challenge(origin: "https://localhost:4001", rp_id: "localhost")

      assert {:error, :invalid_base64} =
               Accounts.finish_webauthn_authentication(
                 user,
                 "not!!b64",
                 "dGVzdA",
                 "dGVzdA",
                 "dGVzdA",
                 challenge
               )
    end
  end
end
