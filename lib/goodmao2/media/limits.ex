defmodule Goodmao2.Media.Limits do
  @moduledoc """
  Resolves the admin-configurable media upload limits (ADR-0005): per-kind byte-size caps and
  min/max pixel dimensions for images and videos.

  Each limit is read from the `Goodmao2.Settings` store (an administrator manages them on
  `/admin/settings`), falling back to the per-environment `config :goodmao2, Goodmao2.Media`
  default when the setting is unset — and to a built-in default if that is missing too. A
  stored value that is blank or not a non-negative integer is ignored (a bad setting can never
  break an upload). Reads are answered from the `Settings` ETS cache, so calling this per upload
  is cheap.

  **`0` means "no bound"** for both floors and ceilings: a min of `0` passes any size, and a max
  of `0` imposes no ceiling — so an administrator lifts a limit by setting the field to `0`.
  The image dimension floor ships at 640×480 (`config/config.exs`); everything else ships
  unbounded by default, purely admin-opt-in.
  """
  alias Goodmao2.Settings

  # Built-in defaults + the canonical field order (drives the admin form). Bytes are absolute;
  # dimensions are pixels; 0 = unbounded. Per-env overrides live in `config :goodmao2,
  # Goodmao2.Media`; a Settings value overrides both at runtime.
  @defaults [
    max_image_bytes: 8_000_000,
    max_video_bytes: 16_000_000,
    min_image_width: 640,
    min_image_height: 480,
    max_image_width: 0,
    max_image_height: 0,
    min_video_width: 0,
    min_video_height: 0,
    max_video_width: 0,
    max_video_height: 0
  ]

  @fields Keyword.keys(@defaults)

  @doc "The configurable limit fields, in display order."
  def fields, do: @fields

  @doc "The `settings` table key backing a limit field (namespaced under `media_`)."
  def setting_key(field) when is_atom(field), do: "media_" <> Atom.to_string(field)

  @doc """
  The effective integer value for `field` — a `Settings` override, else the env/built-in default.
  """
  def get(field) when is_atom(field) do
    case Settings.get(setting_key(field)) do
      nil -> default(field)
      value -> parse(value, default(field))
    end
  end

  @doc "All effective limits as an atom-keyed map (handy for the Purifier and the admin form)."
  def all, do: Map.new(@fields, fn field -> {field, get(field)} end)

  defp default(field) do
    :goodmao2
    |> Application.get_env(Goodmao2.Media, [])
    |> Keyword.get(field, Keyword.fetch!(@defaults, field))
  end

  # A blank or non-integer stored value falls back to the default — never crashes an upload.
  defp parse(value, default) do
    case value |> to_string() |> String.trim() |> Integer.parse() do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end
end
