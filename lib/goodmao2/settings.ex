defmodule Goodmao2.Settings do
  @moduledoc """
  Site-wide system settings: a small global key/value store an administrator manages from
  the Web UI (`Goodmao2Web.AdminLive.Settings`). First occupant: the Web Push VAPID keypair
  (ADR-0011 Stage 2).

  Values are opaque strings. A secret value is encrypted by the writer before it is stored
  (the VAPID private key goes through `Goodmao2.Notifications.WebPush.VapidVault`) — this
  store makes no confidentiality promise of its own.

  Reads are answered from a small ETS cache (`Goodmao2.Settings.Cache`) with a DB fallback;
  writes go through to the DB and refresh the cache. Reads are unauthenticated; **writes are
  admin-gated at the LiveView boundary** — the settings page mounts behind `:require_admin`.
  """
  import Ecto.Query, warn: false

  alias Goodmao2.Repo
  alias Goodmao2.Settings.Cache
  alias Goodmao2.Settings.Setting

  @doc "Returns the string value for `key`, or `nil` if unset. Cached read-through."
  def get(key) when is_binary(key) do
    case Cache.fetch(key) do
      {:ok, value} ->
        value

      :miss ->
        value = Repo.one(from s in Setting, where: s.key == ^key, select: s.value)
        Cache.put(key, value)
        value
    end
  end

  @doc """
  Upserts `key` to `value` and refreshes the cache.

  Returns `{:ok, %Setting{}}` or `{:error, changeset}`. Authorization is the caller's
  responsibility (the admin settings page is gated by `:require_admin`).
  """
  def put(key, value) when is_binary(key) do
    result =
      %Setting{}
      |> Setting.changeset(%{key: key, value: value})
      |> Repo.insert(
        on_conflict: [
          set: [value: value, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        ],
        conflict_target: :key
      )

    case result do
      {:ok, _setting} = ok ->
        Cache.put(key, value)
        ok

      error ->
        error
    end
  end
end
