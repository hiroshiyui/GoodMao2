defmodule Goodmao2Web.Locale do
  @moduledoc """
  Central locale policy for the web layer: the set of shipped locales, their autonym
  labels, their BCP-47 `lang` codes, and per-request resolution
  (cookie → `Accept-Language` → default).

  Used by `Goodmao2Web.Plugs.Locale` (dead views), the `on_mount` locale hook
  (LiveViews), and the header switcher. The locale codes match the Gettext catalog
  directory names under `priv/gettext/` (`en` / `zh_TW` / `ja_JP`).
  """

  @cookie "locale"
  @locales ~w(en zh_TW ja_JP)
  @default "en"

  # Autonyms — each locale named in its own language so it is recognisable whatever
  # the active UI language is. zh_TW is 台灣漢語, never 繁體中文/正體中文 (ADR-0002).
  @labels %{"en" => "English", "zh_TW" => "台灣漢語", "ja_JP" => "日本語"}

  # BCP-47 values for the `<html lang>` attribute.
  @html_lang %{"en" => "en", "zh_TW" => "zh-Hant-TW", "ja_JP" => "ja"}

  @doc "Name of the persistent locale cookie."
  def cookie, do: @cookie

  @doc "The shipped locale codes, base first."
  def known, do: @locales

  @doc "The default/base locale."
  def default, do: @default

  @doc "Whether `locale` is one we ship."
  def known?(locale), do: locale in @locales

  @doc "The autonym label for a locale (falls back to the code)."
  def label(locale), do: Map.get(@labels, locale, locale)

  @doc "The BCP-47 `lang` attribute value for a locale."
  def html_lang(locale), do: Map.get(@html_lang, locale, "en")

  @doc """
  Best matching shipped locale for an `Accept-Language` header value, or `nil` when
  none match. Honours the header's order (which is q-value descending in practice)
  and matches by primary subtag, so `zh-Hant-TW` / `zh-CN` both map to `zh_TW`.
  """
  def from_accept_language(nil), do: nil

  def from_accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.map(fn part ->
      part |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    end)
    |> Enum.find_value(&match_tag/1)
  end

  defp match_tag(""), do: nil

  defp match_tag(tag) do
    cond do
      String.starts_with?(tag, "zh") -> "zh_TW"
      String.starts_with?(tag, "ja") -> "ja_JP"
      String.starts_with?(tag, "en") -> "en"
      true -> nil
    end
  end
end
