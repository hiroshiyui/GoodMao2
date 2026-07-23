defmodule Goodmao2.LocaleParityTest do
  @moduledoc """
  Guards *structural* parity of the Gettext catalogs under `priv/gettext`.

  Guards both structural parity and translation completeness:

    1. Every locale exposes the same set of domains (`.po` files).
    2. Within each domain, every locale carries the same set of `msgid`s
       (a string added to one catalog but not merged into the others fails here).
    3. No entry in any locale carries a `#, fuzzy` flag (fuzzy = stale merge).
    4. Every `msgid` in the `.pot` templates is present in each locale's `.po`
       (i.e. `mix gettext.merge` has been run after the last `mix gettext.extract`).
    5. Every entry in a **target** locale has a non-empty `msgstr`.
    6. Every interpolation placeholder in a `msgid` survives into its translation.

  Checks 1–4 alone were not enough, and the gap was not theoretical: six strings
  sat untranslated in `zh_TW` and `ja_JP` through the 1.0.0 release while this test
  passed. **Parity is not completeness** — a merged-but-empty `msgstr` is
  structurally identical to a translated one, and Gettext falls back to the msgid
  silently, so nothing breaks and nothing warns. Four of the six were an `aria-label`
  and a screen-reader-only table, meaning the only users who met them were the
  ones the localization exists for.

  `en` is the **source** locale: an empty `msgstr` there means "identical to the
  msgid", which is correct and expected, so completeness is asserted only for
  `@target_locales`.

  Check 6 catches a different failure: a translation that drops `%{count}` or
  mistypes it raises `Gettext.Error` at render time, in that locale only — the kind
  of bug that reaches production because the developer never views that page in
  Japanese.

  It only reads files, so it runs async with no DB.
  """
  use ExUnit.Case, async: true

  @gettext_dir Path.join([File.cwd!(), "priv", "gettext"])
  @locales ["en", "zh_TW", "ja_JP"]
  @source_locale "en"
  @target_locales @locales -- [@source_locale]

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

  # Returns `[{msgid, [msgstr, ...]}]` for a catalog — one tuple per entry, with a
  # translation per plural form. Skips the header (`msgid ""`) and obsolete (`#~`)
  # entries, and folds multi-line continuations into their field.
  defp entries(path) do
    path
    |> File.read!()
    |> String.split("\n\n")
    |> Enum.flat_map(&parse_entry/1)
  end

  defp parse_entry(block) do
    acc =
      block
      |> String.split("\n")
      |> Enum.map(&String.trim_leading/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.reduce(%{field: nil, msgid: "", msgstrs: []}, &absorb/2)

    if acc.msgid == "", do: [], else: [{acc.msgid, acc.msgstrs}]
  end

  defp absorb(line, acc) do
    cond do
      # A plural msgid adds no requirement of its own — the msgstr[n] forms below carry it.
      capture_prefixed(line, "msgid_plural") -> %{acc | field: :ignored}
      inner = capture_prefixed(line, "msgid") -> %{acc | field: :msgid, msgid: inner}
      inner = capture_msgstr(line) -> %{acc | field: :msgstr, msgstrs: acc.msgstrs ++ [inner]}
      inner = capture_continuation(line) -> append_continuation(acc, inner)
      true -> %{acc | field: nil}
    end
  end

  # `msgstr "..."` and the plural `msgstr[0] "..."` forms.
  defp capture_msgstr(line) do
    case Regex.run(~r/^msgstr(?:\[\d+\])?\s+"(.*)"\s*$/, line) do
      [_, inner] -> unescape(inner)
      _ -> nil
    end
  end

  defp capture_continuation(line) do
    case Regex.run(~r/^"(.*)"\s*$/, line) do
      [_, inner] -> unescape(inner)
      _ -> nil
    end
  end

  defp append_continuation(%{field: :msgid} = acc, inner), do: %{acc | msgid: acc.msgid <> inner}

  defp append_continuation(%{field: :msgstr, msgstrs: msgstrs} = acc, inner) do
    {init, [last]} = Enum.split(msgstrs, -1)
    %{acc | msgstrs: init ++ [last <> inner]}
  end

  defp append_continuation(acc, _inner), do: acc

  # `%{name}` interpolations, which Gettext resolves at render time — a translation
  # that drops or misspells one raises in that locale only.
  defp placeholders(string) do
    ~r/%\{([^}]+)\}/
    |> Regex.scan(string)
    |> Enum.map(fn [_, name] -> name end)
    |> MapSet.new()
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

  test "every entry in a target locale is actually translated" do
    for locale <- @target_locales, domain <- domains_for(@source_locale) do
      path = po_path(locale, domain)

      untranslated =
        path
        |> entries()
        |> Enum.filter(fn {_msgid, msgstrs} ->
          msgstrs == [] or Enum.any?(msgstrs, &(&1 == ""))
        end)
        |> Enum.map(&elem(&1, 0))

      assert untranslated == [],
             """
             #{domain}.po for #{locale} has #{length(untranslated)} untranslated entrie(s):

               #{Enum.map_join(untranslated, "\n  ", &inspect/1)}

             An empty msgstr falls back to the msgid, so the English text ships silently
             in this locale. Translate them, or if a term is deliberately identical in
             this locale, repeat it in the msgstr so the intent is explicit.
             """
    end
  end

  test "translations keep every interpolation placeholder from their msgid" do
    for locale <- @target_locales, domain <- domains_for(@source_locale) do
      path = po_path(locale, domain)

      broken =
        for {msgid, msgstrs} <- entries(path),
            expected = placeholders(msgid),
            MapSet.size(expected) > 0,
            msgstr <- msgstrs,
            msgstr != "",
            missing = MapSet.difference(expected, placeholders(msgstr)),
            MapSet.size(missing) > 0,
            do: {msgid, msgstr, MapSet.to_list(missing)}

      assert broken == [],
             """
             #{domain}.po for #{locale} drops interpolation placeholders:

               #{Enum.map_join(broken, "\n  ", fn {id, str, missing} -> "#{inspect(id)}\n    -> #{inspect(str)}\n    missing: #{inspect(missing)}" end)}

             Gettext raises at render time when a binding is unused, so this breaks the
             page in this locale only — exactly where it is least likely to be noticed.
             """
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
