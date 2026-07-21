defmodule Goodmao2.Accounts.WebAuthn do
  @moduledoc """
  WebAuthn/FIDO2 credential management and relying-party ceremonies (ADR-0013).

  Wraps the `wax_` library. The public API is re-exported through `Goodmao2.Accounts`.

  ## Registration

  1. `begin_registration/1` — mints a `Wax.Challenge`, stores it in ETS, and returns
     `{token, creation_options_json}` for `navigator.credentials.create`.
  2. `finish_registration/4` — verifies the attestation via `Wax.register/3` and returns
     the extracted credential attributes.
  3. `create_credential/2` — persists the credential.

  ## Authentication

  1. `begin_authentication/1` — mints a challenge with `allowCredentials` from the user's
     enrolled keys, returns `{token, request_options_json}` for `navigator.credentials.get`.
  2. `finish_authentication/6` — verifies the assertion via `Wax.authenticate/6` (which
     enforces sign-count regression / clone detection) and persists the new
     `sign_count` + `last_used_at`.

  Credentials are **hard-deleted** on removal — a revoked key must never authenticate.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Goodmao2.Repo
  alias Goodmao2.Accounts.{User, WebAuthnChallenges, WebAuthnCredential}

  @rp_name "GoodMao"

  # ---------------------------------------------------------------------------
  # CRUD
  # ---------------------------------------------------------------------------

  @doc "Lists a user's enrolled credentials, oldest first."
  @spec list_credentials(User.t()) :: [WebAuthnCredential.t()]
  def list_credentials(%User{} = user) do
    Repo.all(
      from c in WebAuthnCredential,
        where: c.user_id == ^user.id,
        order_by: [asc: :inserted_at, asc: :id]
    )
  end

  @doc "Returns true if the user has at least one enrolled credential."
  @spec webauthn_enabled?(User.t()) :: boolean()
  def webauthn_enabled?(%User{} = user) do
    Repo.exists?(from c in WebAuthnCredential, where: c.user_id == ^user.id)
  end

  @doc "Returns the user's credential count (used by the last-factor guard)."
  @spec credential_count(User.t()) :: non_neg_integer()
  def credential_count(%User{} = user) do
    Repo.aggregate(from(c in WebAuthnCredential, where: c.user_id == ^user.id), :count)
  end

  @doc "Persists a new credential for `user` from the attrs returned by `finish_registration/4`."
  @spec create_credential(User.t(), map()) ::
          {:ok, WebAuthnCredential.t()} | {:error, Ecto.Changeset.t()}
  def create_credential(%User{} = user, attrs) do
    %WebAuthnCredential{user_id: user.id}
    |> WebAuthnCredential.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Hard-deletes a credential by id, scoped to the owning user.

  Returns `{:ok, credential}` or `{:error, :not_found}` when it does not exist or
  belongs to someone else (existence-hidden).
  """
  @spec delete_credential(User.t(), integer() | String.t()) ::
          {:ok, WebAuthnCredential.t()} | {:error, :not_found}
  def delete_credential(%User{} = user, id) do
    case Repo.get_by(WebAuthnCredential, id: id, user_id: user.id) do
      nil -> {:error, :not_found}
      credential -> Repo.delete(credential)
    end
  end

  # ---------------------------------------------------------------------------
  # Registration
  # ---------------------------------------------------------------------------

  @doc """
  Begins registration for `user`. Returns `{challenge_token, creation_options_json}`;
  the token is echoed back on the completion POST to recover the stored challenge.
  """
  @spec begin_registration(User.t()) :: {String.t(), String.t()}
  def begin_registration(%User{} = user) do
    challenge = Wax.new_registration_challenge(origin: origin(), rp_id: rp_id())
    token = WebAuthnChallenges.put(user.id, challenge)

    existing =
      Enum.map(list_credentials(user), fn c ->
        %{type: "public-key", id: Base.url_encode64(c.credential_id, padding: false)}
      end)

    options = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rp: %{name: @rp_name, id: rp_id()},
      user: %{
        id: Base.url_encode64(Integer.to_string(user.id), padding: false),
        name: user.email,
        displayName: user.display_name || user.email
      },
      pubKeyCredParams: [
        %{type: "public-key", alg: -7},
        %{type: "public-key", alg: -257}
      ],
      timeout: 60_000,
      attestation: "none",
      excludeCredentials: existing,
      # `residentKey: "preferred"` requests a discoverable credential (a passkey), which is
      # what makes password-manager providers (Bitwarden, 1Password, iCloud/Google) offer to
      # store the key — without it, browsers fall back to the native hardware-security-key
      # flow only. "preferred" (not "required") keeps plain non-resident FIDO2 keys working too.
      authenticatorSelection: %{
        residentKey: "preferred",
        requireResidentKey: false,
        userVerification: "preferred"
      }
    }

    {token, Jason.encode!(options)}
  end

  @doc """
  Verifies an attestation response and returns `{:ok, attrs}` for `create_credential/2`,
  or `{:error, reason}`.
  """
  @spec finish_registration(User.t(), String.t(), String.t(), Wax.Challenge.t()) ::
          {:ok, map()} | {:error, any()}
  def finish_registration(_user, att_obj_b64, cdj_b64, challenge) do
    with {:ok, attestation_object} <- url_decode64(att_obj_b64),
         {:ok, client_data_json} <- url_decode64(cdj_b64) do
      case Wax.register(attestation_object, client_data_json, challenge) do
        {:ok, {authenticator_data, _result}} ->
          data = authenticator_data.attested_credential_data

          {:ok,
           %{
             credential_id: data.credential_id,
             public_key_cbor: CBOR.encode(data.credential_public_key),
             aaguid: data.aaguid,
             sign_count: authenticator_data.sign_count
           }}

        {:error, _} = err ->
          err
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  @doc """
  Begins authentication for `user`. Returns `{challenge_token, request_options_json}`
  with `allowCredentials` populated from the user's enrolled keys.
  """
  @spec begin_authentication(User.t()) :: {String.t(), String.t()}
  def begin_authentication(%User{} = user) do
    credentials = list_credentials(user)
    challenge = Wax.new_authentication_challenge(origin: origin(), rp_id: rp_id())
    token = WebAuthnChallenges.put(user.id, challenge)

    options = %{
      challenge: Base.url_encode64(challenge.bytes, padding: false),
      rpId: rp_id(),
      allowCredentials:
        Enum.map(credentials, fn c ->
          %{type: "public-key", id: Base.url_encode64(c.credential_id, padding: false)}
        end),
      timeout: 60_000,
      userVerification: "preferred"
    }

    {token, Jason.encode!(options)}
  end

  @doc """
  Verifies an assertion response and, on success, updates the credential's
  `sign_count` + `last_used_at`. Rejects unknown credentials, invalid signatures, and
  non-advancing sign counts (cloned authenticators).
  """
  @spec finish_authentication(
          User.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          Wax.Challenge.t()
        ) :: {:ok, WebAuthnCredential.t()} | {:error, any()}
  def finish_authentication(%User{} = user, cid_b64, ad_b64, cdj_b64, sig_b64, challenge) do
    with {:ok, credential_id} <- url_decode64(cid_b64),
         {:ok, authenticator_data} <- url_decode64(ad_b64),
         {:ok, client_data_json} <- url_decode64(cdj_b64),
         {:ok, signature} <- url_decode64(sig_b64) do
      case Repo.get_by(WebAuthnCredential, credential_id: credential_id, user_id: user.id) do
        nil ->
          {:error, :unknown_credential}

        credential ->
          credentials = [{credential_id, decode_public_key(credential.public_key_cbor)}]

          case Wax.authenticate(
                 credential_id,
                 authenticator_data,
                 signature,
                 client_data_json,
                 challenge,
                 credentials
               ) do
            {:ok, auth_data} ->
              now = DateTime.utc_now() |> DateTime.truncate(:second)

              credential
              |> WebAuthnCredential.update_changeset(%{
                sign_count: auth_data.sign_count,
                last_used_at: now
              })
              |> Repo.update()

            {:error, _} = err ->
              Logger.warning(
                "accounts.webauthn_authenticate_failed user_id=#{user.id} " <>
                  "credential_id=#{Base.url_encode64(credential_id, padding: false)}"
              )

              err
          end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp rp_id, do: Application.get_env(:wax_, :rp_id, "localhost")
  defp origin, do: Application.get_env(:wax_, :origin, "https://localhost:4001")

  # CBOR byte strings decode to %CBOR.Tag{tag: :bytes, value: <<...>>}; unwrap them to
  # plain binaries so the decoded map matches the COSE-key shape Wax expects.
  defp decode_public_key(cbor) do
    {:ok, decoded, _rest} = CBOR.decode(cbor)
    reduce_cbor_binaries(decoded)
  end

  defp reduce_cbor_binaries(%CBOR.Tag{tag: :bytes, value: bytes}), do: bytes

  defp reduce_cbor_binaries(%{} = map),
    do: Map.new(map, fn {k, v} -> {k, reduce_cbor_binaries(v)} end)

  defp reduce_cbor_binaries([_ | _] = list), do: Enum.map(list, &reduce_cbor_binaries/1)
  defp reduce_cbor_binaries(v), do: v

  defp url_decode64(b64) when is_binary(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :invalid_base64}
    end
  end
end
