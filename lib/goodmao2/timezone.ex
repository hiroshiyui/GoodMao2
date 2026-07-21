defmodule Goodmao2.Timezone do
  @moduledoc """
  Timezone policy for GoodMao (ADR-0018).

  Datetimes are stored UTC (`:utc_datetime`) everywhere; this module resolves the *active
  timezone* for a viewer and converts between UTC and that zone for **display** and **input**.

  Resolution order (`resolve/1`): the user's saved preference → the admin-set system default
  (`Settings` key `"default_timezone"`) → the configured last-resort (`:goodmao2,
  :default_timezone`, itself defaulting to `"Etc/UTC"`). "What zone applies to this viewer" is
  answered only here.

  The active zone is stashed in the process dictionary (`put_current/1` / `current/0`), mirroring
  how `Gettext.put_locale` is process-scoped, so the view helpers can shift times without every
  call site threading a zone. `Goodmao2Web.Plugs.Timezone` (dead render) and
  `Goodmao2Web.UserTimezone` (LiveView `on_mount`) establish it per request/socket.

  Backed by the pure-Elixir `tz` database (no runtime HTTP). `all/0` (canonical IANA zones, for
  the settings `<select>`) is derived from `zone1970.tab` at compile time; `known?/1` validates
  against the live tz database, so any real zone a browser reports — including aliases absent
  from the canonical list — is accepted.
  """

  @process_key :goodmao_timezone
  @fallback "Etc/UTC"

  # Canonical IANA zone identifiers, read from the `tz` database's `zone1970.tab` at compile
  # time (tz compiles before us, so its priv dir is populated). `Etc/UTC` is added explicitly —
  # zone1970.tab lists only geographic zones. This is the option list for the picker; validation
  # (`known?/1`) is looser and DB-backed, so a browser-reported alias still passes.
  @zones Tz.IanaDataDir.latest_tzdata_dir_path()
         |> Path.join("zone1970.tab")
         |> File.read!()
         |> String.split("\n", trim: true)
         |> Enum.reject(&String.starts_with?(&1, "#"))
         |> Enum.map(fn line -> line |> String.split("\t") |> Enum.at(2) end)
         |> Enum.reject(&is_nil/1)
         |> Enum.flat_map(&String.split(&1, ","))
         |> Kernel.++(["Etc/UTC"])
         |> Enum.uniq()
         |> Enum.sort()

  @doc "The canonical IANA zone identifiers offered in the timezone picker (sorted)."
  def all, do: @zones

  @doc """
  Whether `tz` is a real timezone the `tz` database can resolve.

  DB-backed (not membership in `all/0`), so aliases a browser may report — e.g.
  `Asia/Chongqing` (→ `Asia/Shanghai`) — validate even though they are not in the picker list.
  """
  def known?(tz) when is_binary(tz), do: match?({:ok, _}, DateTime.now(tz))
  def known?(_), do: false

  @doc "The configured last-resort fallback zone (`:goodmao2, :default_timezone`, else `Etc/UTC`)."
  def default, do: Application.get_env(:goodmao2, :default_timezone, @fallback)

  @doc """
  The admin-set system default (`Settings` key `"default_timezone"`), or `default/0` when unset
  or invalid.
  """
  def system_default do
    case Goodmao2.Settings.get("default_timezone") do
      tz when is_binary(tz) -> if known?(tz), do: tz, else: default()
      _ -> default()
    end
  end

  @doc """
  The active zone for a viewer: user preference → system default → `Etc/UTC`.

  Accepts a `%Goodmao2.Accounts.User{}`, a `%Goodmao2.Accounts.Scope{}`, or `nil` (anonymous).
  """
  def resolve(%Goodmao2.Accounts.Scope{user: user}), do: resolve(user)

  def resolve(%Goodmao2.Accounts.User{timezone: tz}) when is_binary(tz) do
    if known?(tz), do: tz, else: system_default()
  end

  def resolve(_), do: system_default()

  @doc "Stashes the active zone in the process dictionary for the view helpers to read."
  def put_current(tz) when is_binary(tz) do
    Process.put(@process_key, tz)
    tz
  end

  @doc "The active zone for the current process, or `Etc/UTC` if none was established."
  def current, do: Process.get(@process_key, @fallback)

  @doc """
  Shifts a UTC `%DateTime{}` into `tz` for display; returns it unchanged on any failure so
  rendering never crashes on a bad stored zone.
  """
  def to_local(%DateTime{} = dt, tz) when is_binary(tz) do
    case DateTime.shift_zone(dt, tz) do
      {:ok, shifted} -> shifted
      {:error, _} -> dt
    end
  end

  @doc """
  Interprets a user-entered wall-clock value **in `tz`** and returns the equivalent UTC
  `%DateTime{}` for storage — the inverse of `to_local/2`.

  Accepts a `NaiveDateTime` or an ISO-ish string (`"YYYY-MM-DDTHH:MM"`, seconds optional, as
  produced by a `datetime-local` input). On a spring-forward **gap** the just-after instant is
  used; on a fall-back **ambiguous** hour the earlier (first) instant is used. Returns
  `{:ok, utc_dt}` or `:error`.
  """
  def local_naive_to_utc(value, tz) when is_binary(tz) do
    with {:ok, naive} <- to_naive(value),
         {:ok, dt} <- from_naive_in_zone(naive, tz) do
      {:ok, dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second)}
    else
      _ -> :error
    end
  end

  defp to_naive(%NaiveDateTime{} = naive), do: {:ok, naive}

  defp to_naive(str) when is_binary(str) do
    # A datetime-local input omits seconds ("2026-07-21T08:30"); NaiveDateTime needs them.
    normalized = if String.length(str) == 16, do: str <> ":00", else: str
    NaiveDateTime.from_iso8601(normalized)
  end

  defp to_naive(_), do: :error

  defp from_naive_in_zone(naive, tz) do
    case DateTime.from_naive(naive, tz) do
      {:ok, dt} -> {:ok, dt}
      {:gap, _just_before, just_after} -> {:ok, just_after}
      {:ambiguous, first, _second} -> {:ok, first}
      {:error, _} = err -> err
    end
  end
end
