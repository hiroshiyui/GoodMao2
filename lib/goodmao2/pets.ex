defmodule Goodmao2.Pets do
  @moduledoc """
  The Pets context: pets, their access grants, and resource-based authorization.

  Authorization is computed, never global: "can user X do Y to pet Z right now?"
  is derived from an *effective* `PetAccess` grant (active + unexpired). There is
  no administrator backdoor to pet data — the global admin role is orthogonal.

  Capability levels, by effective role:

    * `:read`   — owner, co_caretaker, viewer, vet
    * `:write`  — owner, co_caretaker, vet   (log authoring)
    * `:manage` — owner only                 (edit pet, lifecycle, grants)

  """
  import Ecto.Query, warn: false
  alias Goodmao2.Repo
  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.User
  alias Goodmao2.Pets.{Pet, PetAccess}

  ## Authorization

  @doc """
  Returns the caller's effective `PetAccess` for a pet, or `nil`.

  Effective = `status == "active"` and not expired.
  """
  def effective_access(%Pet{id: pet_id}, %User{id: user_id}),
    do: effective_access(pet_id, user_id)

  def effective_access(pet_id, user_id) when is_integer(pet_id) or is_binary(pet_id) do
    Repo.one(
      from a in PetAccess,
        where: a.pet_id == ^pet_id and a.user_id == ^user_id,
        where: a.status == "active",
        where: is_nil(a.expires_at) or a.expires_at > ^now()
    )
  end

  @doc "Returns the caller's effective role string for a pet, or `nil`."
  def effective_role(pet, user) do
    case effective_access(pet, user) do
      %PetAccess{role: role} -> role
      nil -> nil
    end
  end

  @doc """
  Returns `true` if the user holds at least `level` capability on the pet.

  `level` is one of `:read`, `:write`, `:manage`.
  """
  def can?(pet, %User{} = user, level) do
    role_allows?(effective_role(pet, user), level)
  end

  def can?(_pet, nil, _level), do: false

  defp role_allows?(nil, _level), do: false
  defp role_allows?("owner", _level), do: true
  defp role_allows?("co_caretaker", level) when level in [:read, :write], do: true
  defp role_allows?("vet", level) when level in [:read, :write], do: true
  defp role_allows?("viewer", :read), do: true
  defp role_allows?(_role, _level), do: false

  ## Pets

  @doc """
  Lists pets the user has effective access to, newest first.

  Options:

    * `:ended` — when `true`, only pets whose lifecycle has ended; when `false`
      (default), only `active` pets.
  """
  def list_pets(%User{id: user_id}, opts \\ []) do
    ended? = Keyword.get(opts, :ended, false)

    base =
      from p in Pet,
        join: a in PetAccess,
        on: a.pet_id == p.id and a.user_id == ^user_id,
        where: a.status == "active",
        where: is_nil(a.expires_at) or a.expires_at > ^now(),
        order_by: [desc: p.inserted_at, desc: p.id]

    query =
      if ended? do
        from [p, _a] in base, where: p.lifecycle_status != "active"
      else
        from [p, _a] in base, where: p.lifecycle_status == "active"
      end

    Repo.all(query)
  end

  @doc """
  Fetches a pet the user may read, returning `{:ok, pet}` or `{:error, :not_found}`.

  A pet the caller cannot access is reported as not-found (IDOR-hidden), never as
  forbidden. When `require: :manage`/`:write` is given, the capability is checked too.
  """
  def fetch_pet(%User{} = user, id, opts \\ []) do
    required = Keyword.get(opts, :require, :read)

    case Repo.get(Pet, id) do
      %Pet{} = pet ->
        if can?(pet, user, required), do: {:ok, pet}, else: {:error, :not_found}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Returns a pet by id without authorization (internal use)."
  def get_pet!(id), do: Repo.get!(Pet, id)

  @doc "Changeset for the pet edit form."
  def change_pet(%Pet{} = pet, attrs \\ %{}), do: Pet.changeset(pet, attrs)

  @doc "Changeset for the lifecycle (end-of-care) form."
  def change_pet_lifecycle(%Pet{} = pet, attrs \\ %{}), do: Pet.lifecycle_changeset(pet, attrs)

  @doc """
  Creates a pet and, in the same transaction, the creator's `owner` grant.
  """
  def create_pet(%User{id: user_id}, attrs) do
    changeset =
      %Pet{created_by_user_id: user_id}
      |> Pet.changeset(attrs)

    Repo.transact(fn ->
      with {:ok, pet} <- Repo.insert(changeset),
           {:ok, _access} <-
             %PetAccess{}
             |> PetAccess.changeset(%{
               pet_id: pet.id,
               user_id: user_id,
               role: "owner",
               granted_by_user_id: user_id
             })
             |> Repo.insert() do
        {:ok, pet}
      end
    end)
  end

  @doc "Updates a pet's descriptive attributes. Requires `:manage`."
  def update_pet(%User{} = user, %Pet{} = pet, attrs) do
    with :ok <- require(pet, user, :manage) do
      pet |> Pet.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Transitions a pet's lifecycle (end-of-care). Requires `:manage`."
  def update_pet_lifecycle(%User{} = user, %Pet{} = pet, attrs) do
    with :ok <- require(pet, user, :manage) do
      pet |> Pet.lifecycle_changeset(attrs) |> Repo.update()
    end
  end

  defp require(pet, user, level) do
    if can?(pet, user, level), do: :ok, else: {:error, :unauthorized}
  end

  ## Access grants

  @doc "Lists a pet's non-revoked access grants with the granted user preloaded."
  def list_accesses(%Pet{id: pet_id}) do
    Repo.all(
      from a in PetAccess,
        where: a.pet_id == ^pet_id and a.status == "active",
        order_by: [asc: a.role, asc: a.inserted_at],
        preload: [:user]
    )
  end

  @doc "Changeset for the grant form (defaults to a fresh grant)."
  def change_access(access \\ %PetAccess{}, attrs \\ %{}), do: PetAccess.changeset(access, attrs)

  @doc """
  Grants (or re-grants) access to a pet, identifying the grantee by `@handle` or email.

  Requires the granter to hold `:manage`. Returns `{:error, :grantee_not_found}` if
  no user matches the identifier.
  """
  def grant_access(%User{} = granter, %Pet{} = pet, %{"identifier" => identifier} = attrs) do
    with :ok <- require(pet, granter, :manage),
         %User{} = grantee <- resolve_user(identifier) do
      # This path doubles as the grant-*update* path (insert_or_update), so it must
      # honor the >=1-owner invariant when demoting or time-boxing an existing owner.
      with_owner_lock(pet, fn ->
        existing = Repo.get_by(PetAccess, pet_id: pet.id, user_id: grantee.id)

        with :ok <- guard_owner_retirement(pet, existing, attrs) do
          (existing || %PetAccess{})
          |> PetAccess.changeset(%{
            "pet_id" => pet.id,
            "user_id" => grantee.id,
            "role" => attrs["role"],
            "granted_by_user_id" => granter.id,
            "expires_at" => attrs["expires_at"],
            "status" => "active"
          })
          |> Repo.insert_or_update()
        end
      end)
    else
      nil -> {:error, :grantee_not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  Revokes an access grant. Requires `:manage`, and refuses to remove the pet's
  last effective owner (`{:error, :last_owner}`).
  """
  def revoke_access(%User{} = revoker, %Pet{} = pet, %PetAccess{} = access) do
    with :ok <- require(pet, revoker, :manage) do
      with_owner_lock(pet, fn ->
        with :ok <- guard_last_owner(pet, access) do
          access |> PetAccess.changeset(%{status: "revoked"}) |> Repo.update()
        end
      end)
    end
  end

  # Serializes owner-invariant checks for a pet: two concurrent revokes/demotes can
  # otherwise each see the other as still-effective and both commit into an ownerless
  # state (write skew). Locking the pet's owner rows makes them take turns.
  defp with_owner_lock(%Pet{id: pet_id}, fun) do
    Repo.transact(fn ->
      Repo.all(
        from a in PetAccess,
          where: a.pet_id == ^pet_id and a.role == "owner",
          lock: "FOR UPDATE"
      )

      fun.()
    end)
  end

  # A grant update that demotes an existing effective owner or gives it an expiry must
  # leave another effective owner behind.
  defp guard_owner_retirement(pet, %PetAccess{role: "owner", status: "active"} = existing, attrs) do
    demoting? = attrs["role"] != "owner"
    time_boxing? = not is_nil(attrs["expires_at"])

    if demoting? or time_boxing?, do: guard_last_owner(pet, existing), else: :ok
  end

  defp guard_owner_retirement(_pet, _existing, _attrs), do: :ok

  defp guard_last_owner(pet, %PetAccess{role: "owner"} = access) do
    other_owners =
      Repo.aggregate(
        from(a in PetAccess,
          where: a.pet_id == ^pet.id and a.role == "owner" and a.status == "active",
          where: a.id != ^access.id,
          where: is_nil(a.expires_at) or a.expires_at > ^now()
        ),
        :count
      )

    if other_owners >= 1, do: :ok, else: {:error, :last_owner}
  end

  defp guard_last_owner(_pet, _access), do: :ok

  defp resolve_user(identifier) do
    identifier = String.trim(identifier)

    cond do
      identifier == "" ->
        nil

      String.contains?(identifier, "@") and not String.starts_with?(identifier, "@") ->
        Accounts.get_user_by_email(identifier)

      true ->
        Accounts.get_user_by_handle(identifier)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
