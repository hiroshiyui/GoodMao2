defmodule Goodmao2.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Goodmao2.Repo

  alias Goodmao2.Accounts.{User, UserToken, UserNotifier, VetProfile}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Loads the given user ids as an `%{id => %User{}}` map.

  For labelling audit references (e.g. the editor of a log revision) in one query; unknown
  or `nil` ids are simply absent from the map.
  """
  def get_users_map(ids) when is_list(ids) do
    ids = ids |> Enum.reject(&is_nil/1) |> Enum.uniq()

    from(u in User, where: u.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  ## Administration (site overview)

  @doc "Total number of registered users — for the admin site overview."
  def count_users, do: Repo.aggregate(User, :count)

  @doc """
  The configured site-owner email that gates first-account registration, or `nil`
  when registration is open (the first account to register becomes the administrator).
  Mirrors the check in `authorize_first_registration/2`.
  """
  def site_owner_email do
    case Application.get_env(:goodmao2, :site_owner_email) do
      owner when is_binary(owner) and owner != "" -> owner
      _ -> nil
    end
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    # The first registered account becomes the sole global administrator. On a public
    # deploy that is a race an attacker can win, so when `:site_owner_email` is
    # configured only that address may create the first account (checked before any
    # insert). Returns `{:error, :not_site_owner}` otherwise.
    first? = not Repo.exists?(User)

    with :ok <- authorize_first_registration(first?, attrs) do
      changeset = User.email_changeset(%User{}, attrs)
      changeset = if first?, do: Ecto.Changeset.change(changeset, is_admin: true), else: changeset

      Repo.insert(changeset)
    end
  end

  defp authorize_first_registration(false, _attrs), do: :ok

  defp authorize_first_registration(true, attrs) do
    case Application.get_env(:goodmao2, :site_owner_email) do
      owner when is_binary(owner) and owner != "" ->
        email = attrs[:email] || attrs["email"] || ""

        if String.downcase(to_string(email)) == String.downcase(owner),
          do: :ok,
          else: {:error, :not_site_owner}

      _ ->
        :ok
    end
  end

  @doc """
  Fetches a user by their public `@handle` (case-insensitive), or `nil`.

  The leading `@`, if present, is stripped before lookup.
  """
  def get_user_by_handle(handle) when is_binary(handle) do
    normalized = handle |> String.trim() |> String.trim_leading("@") |> String.downcase()
    if normalized == "", do: nil, else: Repo.get_by(User, handle: normalized)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user's editable profile.
  """
  def change_user_profile(user, attrs \\ %{}, opts \\ []) do
    User.profile_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user's editable profile (display name and handle).
  """
  def update_user_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  ## Veterinarian profiles

  @doc "Returns the user's `VetProfile`, or `nil`."
  def get_vet_profile(%User{id: user_id}), do: Repo.get_by(VetProfile, user_id: user_id)

  @doc "Changeset for the vet-credentials submission form."
  def change_vet_profile(%VetProfile{} = profile \\ %VetProfile{}, attrs \\ %{}),
    do: VetProfile.submit_changeset(profile, attrs)

  @doc """
  Submits (or re-submits) the user's veterinarian credentials for review.

  Any existing profile is updated in place; a re-submission returns it to `pending`.
  """
  def submit_vet_profile(%User{id: user_id} = user, attrs) do
    (get_vet_profile(user) || %VetProfile{user_id: user_id})
    |> VetProfile.submit_changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc "Returns `true` if the user holds a **verified** veterinarian profile."
  def verified_vet?(%User{} = user) do
    case get_vet_profile(user) do
      %VetProfile{verification_status: "verified"} -> true
      _ -> false
    end
  end

  def verified_vet?(_), do: false

  @doc "Lists vet profiles awaiting administrator review, oldest first, user preloaded."
  def list_pending_vet_profiles do
    Repo.all(
      from p in VetProfile,
        where: p.verification_status == "pending",
        order_by: [asc: p.inserted_at, asc: p.id],
        preload: [:user]
    )
  end

  @doc "Marks a vet profile verified. Requires the acting user to be the administrator."
  def verify_vet_profile(%User{is_admin: true, id: admin_id}, %VetProfile{} = profile),
    do: profile |> VetProfile.review_changeset("verified", admin_id) |> Repo.update()

  def verify_vet_profile(_user, _profile), do: {:error, :unauthorized}

  @doc "Marks a vet profile rejected. Requires the acting user to be the administrator."
  def reject_vet_profile(%User{is_admin: true, id: admin_id}, %VetProfile{} = profile),
    do: profile |> VetProfile.review_changeset("rejected", admin_id) |> Repo.update()

  def reject_vet_profile(_user, _profile), do: {:error, :unauthorized}

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Goodmao2.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    changeset = User.email_changeset(user, attrs, opts)

    case Keyword.fetch(opts, :current_password) do
      {:ok, current_password} -> User.validate_current_password(changeset, current_password)
      :error -> changeset
    end
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Goodmao2.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    changeset = User.password_changeset(user, attrs, opts)

    case Keyword.fetch(opts, :current_password) do
      {:ok, current_password} -> User.validate_current_password(changeset, current_password)
      :error -> changeset
    end
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc """
  Updates the user password, gated by their current password.

  Verifies `current_password` before applying the change (defense in depth on top of
  sudo mode). A wrong current password invalidates the changeset, so no update runs and
  no tokens are rotated — it returns `{:error, %Ecto.Changeset{}}` with a
  `:current_password` error. On success, returns `{:ok, {user, expired_tokens}}` and all
  of the user's tokens are rotated, exactly like `update_user_password/2`.

  ## Examples

      iex> update_user_password(user, "current", %{password: "new valid password"})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, "wrong", %{password: "new valid password"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, current_password, attrs) do
    user
    |> User.password_changeset(attrs)
    |> User.validate_current_password(current_password)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  @doc """
  Deletes auth tokens past their validity window; returns the count deleted.

  Tokens are only checked for expiry at read time, and are otherwise deleted only on
  a specific user action (logout, email/password change) — so expired rows accumulate.
  The `Goodmao2.Accounts.TokenJanitor` Oban cron calls this daily to sweep them.
  """
  def delete_expired_tokens do
    {count, _} = Repo.delete_all(UserToken.expired_tokens_query())
    count
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
