defmodule Goodmao2.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  # Reserved handles that may not be claimed by a user (routes, roles, support names,
  # impersonation bait).
  @reserved_handles ~w(admin administrator superuser sysadmin operator moderator mod system
                       root support help about auth login logout register settings account
                       user users owner staff official team goodmao pets vet vets vetprofile
                       me here all everyone anonymous none null undefined shared media api)

  # The allowed pet-timeline page sizes; the first is the default. Single source of truth for
  # the schema default, the changeset whitelist, and the LiveView dropdown.
  @timeline_page_sizes [25, 50, 100]
  def timeline_page_sizes, do: @timeline_page_sizes

  schema "users" do
    field :email, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    # Public @handle used to mention/invite the user. Distinct from the email
    # (UserName) and the free-text display name.
    field :handle, :string
    field :display_name, :string
    # The sole global role — the first registered account. Not a per-pet role.
    field :is_admin, :boolean, default: false

    # Preferred IANA timezone for displaying/entering times (ADR-0018). Nil ⇒ fall back to the
    # admin system default, then Etc/UTC. Validated against the live tz database.
    field :timezone, :string

    # How many entries the pet timeline shows per page (roadmap §8). Whitelisted to
    # `@timeline_page_sizes`; the first is the default.
    field :timeline_page_size, :integer, default: 25

    # Two-factor authentication (ADR-0013). `totp_secret` holds the AES-256-GCM
    # ciphertext of the shared secret (never the raw secret); `totp_confirmed_at` is
    # set once the user proves possession with a valid code (nil ⇒ TOTP disabled).
    field :totp_secret, :binary, redact: true
    field :totp_confirmed_at, :utc_datetime
    # Window timestamp of the last TOTP code consumed at login — passed as `since:` to reject
    # replaying a just-used code within its 30s window (ADR-0013).
    field :totp_last_used_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  A changeset for the user's editable profile: display name and public handle.

  The handle is optional but, once set, is normalized to lowercase-canonical and
  validated against the handle rules (3–30 chars of `a–z 0–9 . _`, must start with a
  letter or number, may not end with a dot, no `..`, no reserved words). Uniqueness is
  case-insensitive via the `citext` column.
  """
  def profile_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:display_name, :handle, :timezone])
    |> validate_length(:display_name, max: 80)
    |> normalize_handle()
    |> validate_handle(opts)
    |> validate_timezone()
  end

  @doc """
  A changeset for lightweight UI preferences that persist per account — currently the
  timeline page size. Whitelisted so a crafted value can't request an unbounded page.
  """
  def preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [:timeline_page_size])
    |> validate_inclusion(:timeline_page_size, @timeline_page_sizes)
  end

  # A blank selection clears the preference (fall back to system default); any other value must
  # be a zone the tz database recognises.
  defp validate_timezone(changeset) do
    case get_change(changeset, :timezone) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :timezone, nil)

      tz ->
        if Goodmao2.Timezone.known?(tz),
          do: changeset,
          else: add_error(changeset, :timezone, "is not a valid timezone")
    end
  end

  defp normalize_handle(changeset) do
    case get_change(changeset, :handle) do
      nil ->
        changeset

      handle ->
        normalized = handle |> String.trim() |> String.downcase()
        # An empty string clears the handle back to nil.
        if normalized == "",
          do: put_change(changeset, :handle, nil),
          else: put_change(changeset, :handle, normalized)
    end
  end

  defp validate_handle(changeset, opts) do
    changeset =
      if get_field(changeset, :handle) do
        changeset
        |> validate_length(:handle, min: 3, max: 30)
        |> validate_format(:handle, ~r/^[a-z0-9._]+$/,
          message: "may only contain lowercase letters, numbers, dots and underscores"
        )
        |> validate_format(:handle, ~r/^[a-z0-9]/, message: "must start with a letter or number")
        |> validate_format(:handle, ~r/[^.]$/, message: "may not end with a dot")
        |> validate_exclusion(:handle, @reserved_handles, message: "is reserved")
        |> validate_no_double_dot()
      else
        changeset
      end

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:handle, Goodmao2.Repo)
      |> unique_constraint(:handle)
    else
      changeset
    end
  end

  defp validate_no_double_dot(changeset) do
    handle = get_field(changeset, :handle)

    if is_binary(handle) and String.contains?(handle, "..") do
      add_error(changeset, :handle, "may not contain consecutive dots")
    else
      changeset
    end
  end

  @doc """
  Marks the user as the global administrator.
  """
  def admin_changeset(user) do
    change(user, is_admin: true)
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Goodmao2.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Validates that `current_password` matches the user's existing password.

  Used to gate self-service password and email changes (defense in depth on top of
  sudo mode). Adds a `:current_password` error to the changeset on mismatch.

  Passwordless accounts (magic-link users with no `hashed_password` yet) have nothing
  to verify, so the check is skipped — this still allows an initial password set.
  """
  def validate_current_password(changeset, current_password) do
    cond do
      is_nil(changeset.data.hashed_password) -> changeset
      valid_password?(changeset.data, current_password) -> changeset
      true -> add_error(changeset, :current_password, "is not valid")
    end
  end

  @doc """
  A changeset for enabling or disabling TOTP two-factor authentication.

  Casts only the `totp_secret` (encrypted ciphertext), `totp_confirmed_at`, and
  `totp_last_used_at` — the caller (`Accounts.TwoFactor`) is responsible for encrypting the
  secret before it ever reaches this changeset.
  """
  def totp_changeset(user, attrs) do
    cast(user, attrs, [:totp_secret, :totp_confirmed_at, :totp_last_used_at])
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Goodmao2.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
