defmodule Goodmao2.Reports do
  @moduledoc """
  The Reports context: generated, point-in-time **health summary reports** for a pet.

  A report freezes a snapshot of the timeline over a date range (`Logs.shareable_entries/3`,
  which **excludes every private entry**) so it stays faithful to its moment and is safe to
  hand to a vet — including through an optional **expiring** anonymous share link.

  Authorization is delegated to `Pets`: generating, sharing, and deleting require `:manage`
  (owner); listing and reading require `:read`. The anonymous token path
  (`fetch_report_by_token/1`) is the sole exception — it is gated only by an unexpired,
  matching token.
  """
  import Ecto.Query, warn: false

  alias Goodmao2.Repo
  alias Goodmao2.Accounts.User
  alias Goodmao2.Logs
  alias Goodmao2.Pets
  alias Goodmao2.Pets.Pet
  alias Goodmao2.Reports.HealthSummaryReport

  @snapshot_version 1

  # The most entries one snapshot freezes. Larger periods are refused (`:too_many_entries`)
  # rather than silently cut short: a report that quietly drops its newest entries reads as a
  # complete record to the vet holding it.
  @max_entries 5000
  @token_bytes 32

  ## Generation

  @doc """
  Generates and stores a frozen health-summary snapshot for `pet` over a date range.

  Requires `:manage`. `period_start`/`period_end` are `Date`s (inclusive) as the generator
  sees them: the window runs from start 00:00:00 to end 23:59:59 **in the generator's
  timezone** (`Goodmao2.Timezone.resolve/1`, ADR-0018), and that zone is frozen into the
  snapshot (`"timezone"`) so the period renders as entered to every reader — see
  `period_timezone/1`.

  A period holding more than `max_entries/0` shareable entries is refused with
  `{:error, :too_many_entries}` instead of being cut short.
  """
  def generate_report(%User{} = user, %Pet{} = pet, %{
        period_start: %Date{} = period_start,
        period_end: %Date{} = period_end
      }) do
    with :ok <- require(pet, user, :manage),
         :ok <- ensure_visible(pet) do
      tz = Goodmao2.Timezone.resolve(user)
      from_dt = local_day_bound(period_start, ~T[00:00:00], tz)
      to_dt = local_day_bound(period_end, ~T[23:59:59], tz)

      entries =
        Logs.shareable_entries(user, pet, from: from_dt, to: to_dt, limit: @max_entries + 1)

      if length(entries) > @max_entries,
        do: {:error, :too_many_entries},
        else: insert_report(user, pet, entries, tz, from_dt, to_dt)
    end
  end

  @doc "The most entries a report may hold; a longer period is `{:error, :too_many_entries}`."
  def max_entries, do: @max_entries

  defp insert_report(user, pet, entries, tz, from_dt, to_dt) do
    content = %{
      "version" => @snapshot_version,
      "generated_at" => DateTime.to_iso8601(now()),
      "timezone" => tz,
      "pet" => pet_descriptor(pet),
      "entries" => Enum.map(entries, &entry_snapshot/1)
    }

    %HealthSummaryReport{}
    |> HealthSummaryReport.create_changeset(%{
      pet_id: pet.id,
      generated_by_user_id: user.id,
      period_start: from_dt,
      period_end: to_dt,
      content: content
    })
    |> Repo.insert()
  end

  defp pet_descriptor(%Pet{} = pet) do
    Map.new(
      [:name, :species, :breed, :color, :sex, :birth_date, :neutered, :weight_unit],
      fn key -> {to_string(key), encode_value(Map.get(pet, key))} end
    )
  end

  defp entry_snapshot(entry) do
    %{
      "type" => entry.type,
      "occurred_at" => DateTime.to_iso8601(entry.occurred_at),
      "note" => entry.note,
      "data" => entry.data || %{},
      "visibility" => entry.visibility
    }
  end

  defp encode_value(%Date{} = d), do: Date.to_iso8601(d)
  defp encode_value(value), do: value

  ## Reads

  @doc """
  Lists a pet's non-deleted reports, newest first. Requires `:read`.

  A pet whose history is hidden (ADR-0003) lists nothing: a report is a frozen slice of that
  history, so it hides with it, like entries and medications do.
  """
  def list_reports(%User{} = user, %Pet{} = pet) do
    if readable?(pet, user) do
      Repo.all(
        from r in HealthSummaryReport,
          where: r.pet_id == ^pet.id and is_nil(r.deleted_at),
          order_by: [desc: r.inserted_at, desc: r.id]
      )
    else
      []
    end
  end

  @doc """
  Fetches one non-deleted report scoped to a readable pet, or `nil` (IDOR-hidden).
  Requires `:read`; `nil` while the pet's history is hidden.
  """
  def fetch_report(%User{} = user, %Pet{} = pet, id) do
    with true <- readable?(pet, user),
         {:ok, id} <- Goodmao2.ID.normalize(id) do
      Repo.one(
        from r in HealthSummaryReport,
          where: r.id == ^id and r.pet_id == ^pet.id and is_nil(r.deleted_at)
      )
    else
      _ -> nil
    end
  end

  @doc "Soft-deletes a report. Requires `:manage`."
  def delete_report(%User{} = user, %Pet{} = pet, %HealthSummaryReport{} = report) do
    with :ok <- ensure_report_of(pet, report),
         :ok <- require(pet, user, :manage) do
      report |> change_deleted() |> Repo.update()
    end
  end

  ## Anonymous share link

  @doc """
  Mints an expiring anonymous share link for a report, returning the **raw** token once.

  Only the SHA-256 hash is stored. Requires `:manage`; `expires_at` must be in the future.
  Returns `{:ok, {report, raw_token}}`.
  """
  def create_share_token(
        %User{} = user,
        %Pet{} = pet,
        %HealthSummaryReport{} = report,
        expires_at
      ) do
    with :ok <- ensure_report_of(pet, report),
         :ok <- require(pet, user, :manage),
         :ok <- validate_future(expires_at) do
      token = :crypto.strong_rand_bytes(@token_bytes)
      hash = :crypto.hash(:sha256, token)

      report
      |> Ecto.Changeset.change(%{
        share_token_hash: hash,
        share_expires_at: DateTime.truncate(expires_at, :second)
      })
      |> Repo.update()
      |> case do
        {:ok, report} -> {:ok, {report, Base.url_encode64(token, padding: false)}}
        error -> error
      end
    end
  end

  @doc "Revokes a report's share link. Requires `:manage`."
  def revoke_share_token(%User{} = user, %Pet{} = pet, %HealthSummaryReport{} = report) do
    with :ok <- ensure_report_of(pet, report),
         :ok <- require(pet, user, :manage) do
      report
      |> Ecto.Changeset.change(%{share_token_hash: nil, share_expires_at: nil})
      |> Repo.update()
    end
  end

  @doc """
  Resolves a raw share token to its live report, or `nil`.

  Public (no pet authorization) — the only gate is a matching, **unexpired** token on a
  non-deleted report whose pet's history is not hidden (hiding the history kills every live
  link, as it does for shared entries). A malformed token, an expired link, or a revoked one
  all return `nil`.
  """
  def fetch_report_by_token(token) when is_binary(token) do
    case Base.url_decode64(token, padding: false) do
      {:ok, raw} ->
        hash = :crypto.hash(:sha256, raw)

        Repo.one(
          from r in HealthSummaryReport,
            join: p in Goodmao2.Pets.Pet,
            on: p.id == r.pet_id,
            where: r.share_token_hash == ^hash and is_nil(r.deleted_at),
            where: not is_nil(r.share_expires_at) and r.share_expires_at > ^now(),
            where: not p.history_hidden
        )

      :error ->
        nil
    end
  end

  def fetch_report_by_token(_), do: nil

  ## Helpers

  defp require(pet, user, level) do
    if Pets.can?(pet, user, level), do: :ok, else: {:error, :unauthorized}
  end

  # Both read from the database now, never from the `%Pet{}` snapshot the caller holds.
  defp readable?(pet, user), do: Pets.can?(pet, user, :read) and not Pets.history_hidden?(pet)

  defp ensure_visible(pet) do
    if Pets.history_hidden?(pet), do: {:error, :unauthorized}, else: :ok
  end

  # The pet authorizes the caller; the report must belong to that same pet, or `:manage` on one
  # pet would reach any report struct a caller holds.
  defp ensure_report_of(%Pet{id: pet_id}, %HealthSummaryReport{pet_id: pet_id}), do: :ok
  defp ensure_report_of(_pet, _report), do: {:error, :unauthorized}

  defp validate_future(%DateTime{} = dt) do
    if DateTime.after?(dt, now()), do: :ok, else: {:error, :expiry_in_past}
  end

  defp validate_future(_), do: {:error, :expiry_in_past}

  defp change_deleted(report), do: Ecto.Changeset.change(report, %{deleted_at: now()})

  @doc """
  The zone a report's period was entered in, for rendering `period_start`/`period_end` as the
  generator's dates. Reports generated before the zone was frozen used UTC days, so `"Etc/UTC"`
  renders those correctly too.
  """
  def period_timezone(%HealthSummaryReport{content: content}), do: content_timezone(content)

  @doc "As `period_timezone/1`, from a report's frozen `content` map."
  def content_timezone(%{"timezone" => tz}) when is_binary(tz), do: tz
  def content_timezone(_content), do: "Etc/UTC"

  # A day's wall-clock bound in `tz`, as UTC. `tz` comes from `Timezone.resolve/1`, which only
  # returns known zones, so the conversion cannot fail.
  defp local_day_bound(%Date{} = d, %Time{} = t, tz) do
    {:ok, utc} = Goodmao2.Timezone.local_naive_to_utc(NaiveDateTime.new!(d, t), tz)
    utc
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
