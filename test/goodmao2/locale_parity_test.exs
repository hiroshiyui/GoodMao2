defmodule Goodmao2.LocaleParityTest do
  @moduledoc """
  Guards *structural* parity of the Gettext catalogs under `priv/gettext`.

  This does NOT assert that anything is actually translated — `zh_TW` and
  `ja_JP` are intentionally scaffolded with empty `msgstr`s (translation
  completeness is deferred per the roadmap). What it does guard is that the
  catalogs stay in sync structurally, which is the real drift risk:

    1. Every locale exposes the same set of domains (`.po` files).
    2. Within each domain, every locale carries the same set of `msgid`s
       (a string added to one catalog but not merged into the others fails here).
    3. No entry in any locale carries a `#, fuzzy` flag (fuzzy = stale merge).
    4. Every `msgid` in the `.pot` templates is present in each locale's `.po`
       (i.e. `mix gettext.merge` has been run after the last `mix gettext.extract`).

  It only reads files, so it runs async with no DB.
  """
  use ExUnit.Case, async: true

  @gettext_dir Path.join([File.cwd!(), "priv", "gettext"])
  @locales ["en", "zh_TW", "ja_JP"]

  setup_all do
    assert File.dir?(@gettext_dir),
           "expected gettext catalog dir at #{@gettext_dir} when run via `mix test`"

    :ok
  end

  # --- .po/.pot parser -------------------------------------------------------

  # Returns the set of msgids (and msgid_plurals) declared in a catalog file,
  # excluding the header entry (`msgid ""`). Handles the multi-line form where
  # `msgid ""` / `msgid_plural ""` is followed by continuation string lines.
  defp msgids(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> parse_msgids([])
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp parse_msgids([], acc), do: acc

  defp parse_msgids([line | rest], acc) do
    trimmed = String.trim_leading(line)

    cond do
      # start of a msgid or msgid_plural: capture the (possibly empty) inline
      # string, then fold in any following continuation string lines.
      match = capture_prefixed(trimmed, "msgid_plural") ->
        {full, rest2} = collect_continuations(match, rest)
        parse_msgids(rest2, [full | acc])

      match = capture_prefixed(trimmed, "msgid") ->
        {full, rest2} = collect_continuations(match, rest)
        parse_msgids(rest2, [full | acc])

      true ->
        parse_msgids(rest, acc)
    end
  end

  # Matches `keyword "..."` and returns the unescaped inner string, else nil.
  defp capture_prefixed(line, keyword) do
    case Regex.run(~r/^#{keyword}\s+"(.*)"\s*$/, line) do
      [_, inner] -> unescape(inner)
      _ -> nil
    end
  end

  # After a `msgid ""` line, following bare `"..."` lines are continuations.
  defp collect_continuations(acc, [line | rest]) do
    case Regex.run(~r/^\s*"(.*)"\s*$/, line) do
      [_, inner] -> collect_continuations(acc <> unescape(inner), rest)
      _ -> {acc, [line | rest]}
    end
  end

  defp collect_continuations(acc, []), do: {acc, []}

  defp unescape(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp fuzzy?(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.any?(fn line ->
      line = String.trim_leading(line)
      String.starts_with?(line, "#,") and String.contains?(line, "fuzzy")
    end)
  end

  defp domains_for(locale) do
    Path.join([@gettext_dir, locale, "LC_MESSAGES", "*.po"])
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".po"))
    |> Enum.sort()
  end

  defp po_path(locale, domain),
    do: Path.join([@gettext_dir, locale, "LC_MESSAGES", "#{domain}.po"])

  defp pot_path(domain), do: Path.join(@gettext_dir, "#{domain}.pot")

  # --- tests -----------------------------------------------------------------

  test "every locale exposes the same set of domains" do
    per_locale = Map.new(@locales, fn locale -> {locale, domains_for(locale)} end)
    reference = per_locale["en"]

    for {locale, domains} <- per_locale do
      assert domains == reference,
             "domain drift for #{locale}: has #{inspect(domains)}, expected #{inspect(reference)}"
    end
  end

  test "each domain carries the same set of msgids across all locales" do
    for domain <- domains_for("en") do
      per_locale = Map.new(@locales, fn locale -> {locale, msgids(po_path(locale, domain))} end)
      reference = per_locale["en"]

      for {locale, ids} <- per_locale, locale != "en" do
        missing = MapSet.difference(reference, ids)
        extra = MapSet.difference(ids, reference)

        assert MapSet.size(missing) == 0 and MapSet.size(extra) == 0,
               """
               msgid drift in #{domain}.po for locale #{locale}:
                 missing (in en, not #{locale}): #{inspect(MapSet.to_list(missing))}
                 extra   (in #{locale}, not en): #{inspect(MapSet.to_list(extra))}
               Run `mix gettext.extract && mix gettext.merge priv/gettext` to sync.
               """
      end
    end
  end

  test "no .po entry carries a fuzzy flag" do
    for locale <- @locales, domain <- domains_for("en") do
      path = po_path(locale, domain)

      refute fuzzy?(path),
             "#{Path.relative_to(path, File.cwd!())} contains `#, fuzzy` entries — resolve the stale merge."
    end
  end

  test "every .pot msgid is present in each locale's .po (merge is up to date)" do
    for domain <- domains_for("en") do
      pot = pot_path(domain)
      assert File.exists?(pot), "missing template #{Path.relative_to(pot, File.cwd!())}"
      template_ids = msgids(pot)

      for locale <- @locales do
        po_ids = msgids(po_path(locale, domain))
        missing = MapSet.difference(template_ids, po_ids)

        assert MapSet.size(missing) == 0,
               """
               #{domain}.po for #{locale} is missing msgids present in #{domain}.pot:
                 #{inspect(MapSet.to_list(missing))}
               Run `mix gettext.merge priv/gettext` after `mix gettext.extract`.
               """
      end
    end
  end
end
