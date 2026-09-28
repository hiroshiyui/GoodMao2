defmodule Goodmao2.LocaleParityTest do
  @moduledoc """
  Guards *structural* parity and translation completeness of the Gettext catalogs
  under `priv/gettext`:

    1. Every locale exposes the same set of domains (`.po` files).
    2. Within each domain, every locale carries the same set of `msgid`s
       (a string added to one catalog but not merged into the others fails here).
    3. No entry in any locale carries a `#, fuzzy` flag (fuzzy = stale merge).
    4. Every locale's `.po` holds **exactly** its `.pot` template's msgids — none
       missing (`mix gettext.merge` was not run) and none orphaned (a msgid the
       template no longer has, which nothing will ever render or re-check).
    5. Every entry in a **target** locale has a non-empty `msgstr`.
    6. Every `en` `msgstr` is blank or equal to its own msgid (`msgid_plural` for a
       plural form).
    7. Every interpolation placeholder in a `msgid` survives into its translation,
       and no translation uses a binding its msgid does not provide.

  Checks 1–4 alone were not enough, and the gap was not theoretical: six strings
  sat untranslated in `zh_TW` and `ja_JP` through the 1.0.0 release while this test
  passed. **Parity is not completeness** — a merged-but-empty `msgstr` is
  structurally identical to a translated one, and Gettext falls back to the msgid
  silently, so nothing breaks and nothing warns. Four of the six were an `aria-label`
  and a screen-reader-only table, meaning the only users who met them were the
  ones the localization exists for.

  `en` is the **source** locale: an empty `msgstr` there means "identical to the
  msgid", which is correct and expected, so completeness is asserted only for
  `@target_locales`. That exemption is blind to a *filled* `en` entry, which is
  check 6: `mix gettext.merge` fuzzy-matches into `en` as readily as into any other
  locale, and Gettext serves the result — Baudrate shipped "Push" for `Published`
  that way. A corrected English copy would be a second place the English lives, so
  the fix is always to blank the msgstr.

  Check 7 catches the interpolation failures, which differ by direction. A
  translation that **drops** `%{count}` renders without error and silently loses
  the value. A translation that uses a binding its msgid **does not provide** (a
  typo, or a placeholder copied from a neighbouring entry) has nothing to bind:
  Gettext logs an error and renders the literal `%{name}` text — in that locale
  only, which is exactly where the developer never looks.

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

  # Returns the set of `{msgid, msgid_plural}` keys declared in a catalog file
  # (`msgid_plural` is `nil` for a singular entry), excluding the header.
  defp msgids(path) do
    path
    |> entries()
    |> MapSet.new(fn {msgid, plural, _msgstrs} -> {msgid, plural} end)
  end

  # Returns `[{msgid, msgid_plural | nil, [msgstr, ...]}]` for a catalog — one tuple
  # per entry, with a translation per plural form. Skips the header (`msgid ""`) and
  # obsolete (`#~`) entries, and folds multi-line continuations into their field.
  defp entries(path) do
    path
    |> File.read!()
    |> String.split(~r/\n\s*\n/)
    |> Enum.flat_map(&parse_entry/1)
  end

  defp parse_entry(block) do
    acc =
      block
      |> String.split("\n")
      |> Enum.map(&String.trim_leading/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.reduce(%{field: nil, msgid: "", plural: nil, msgstrs: []}, &absorb/2)

    if acc.msgid == "", do: [], else: [{acc.msgid, acc.plural, acc.msgstrs}]
  end

  defp absorb(line, acc) do
    cond do
      inner = capture_prefixed(line, "msgid_plural") -> %{acc | field: :plural, plural: inner}
      inner = capture_prefixed(line, "msgid") -> %{acc | field: :msgid, msgid: inner}
      inner = capture_msgstr(line) -> %{acc | field: :msgstr, msgstrs: acc.msgstrs ++ [inner]}
      inner = capture_continuation(line) -> append_continuation(acc, inner)
      true -> %{acc | field: nil}
    end
  end

  # Matches `keyword "..."` and returns the unescaped inner string, else nil.
  defp capture_prefixed(line, keyword) do
    case Regex.run(~r/^#{keyword}\s+"(.*)"\s*$/, line) do
      [_, inner] -> unescape(inner)
      _ -> nil
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

  defp append_continuation(%{field: :plural} = acc, inner),
    do: %{acc | plural: acc.plural <> inner}

  defp append_continuation(%{field: :msgstr, msgstrs: msgstrs} = acc, inner) do
    {init, [last]} = Enum.split(msgstrs, -1)
    %{acc | msgstrs: init ++ [last <> inner]}
  end

  defp append_continuation(acc, _inner), do: acc

  defp unescape(str) do
    str
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp describe({msgid, nil}), do: inspect(msgid)
  defp describe({msgid, plural}), do: "#{inspect(msgid)} / plural #{inspect(plural)}"

  # `%{name}` interpolations, which Gettext resolves at render time. A dropped one
  # silently loses its value; one the msgid does not provide renders as the literal
  # `%{name}` text (with a logged error) — both in that locale only.
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
        |> Enum.filter(fn {_msgid, _plural, msgstrs} ->
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

  test "every en msgstr is blank or its own source text" do
    for domain <- domains_for(@source_locale) do
      wrong =
        for {msgid, plural, msgstrs} <- entries(po_path(@source_locale, domain)),
            msgstr <- msgstrs,
            msgstr not in ["", msgid, plural],
            do: "#{describe({msgid, plural})}\n    renders as #{inspect(msgstr)}"

      assert wrong == [],
             """
             #{domain}.po for en renders text that is not its own source string:

               #{Enum.join(wrong, "\n  ")}

             An `en` msgstr should be empty — Gettext then falls back to the msgid,
             which *is* the English. A filled one that differs is usually the fuzzy
             matcher's work: `mix gettext.merge` attaches a translation from a
             similar msgid, and Gettext serves it. Blank the msgstr rather than
             correcting it; a corrected copy is a second place the English lives.
             """
    end
  end

  test "translations keep every placeholder and add none their msgid lacks" do
    for locale <- @locales, domain <- domains_for(@source_locale) do
      broken =
        for {msgid, plural, msgstrs} <- entries(po_path(locale, domain)),
            required = placeholders(msgid),
            # A plural entry binds `count` implicitly, plus anything in either form.
            provided =
              if(plural,
                do: required |> MapSet.union(placeholders(plural)) |> MapSet.put("count"),
                else: required
              ),
            msgstr <- msgstrs,
            msgstr != "",
            dropped = MapSet.difference(required, placeholders(msgstr)),
            stray = MapSet.difference(placeholders(msgstr), provided),
            MapSet.size(dropped) > 0 or MapSet.size(stray) > 0,
            do: {msgid, msgstr, MapSet.to_list(dropped), MapSet.to_list(stray)}

      assert broken == [],
             """
             #{domain}.po for #{locale} has interpolation placeholders out of step with the msgid:

               #{Enum.map_join(broken, "\n  ", fn {id, str, dropped, stray} -> "#{inspect(id)}\n    -> #{inspect(str)}\n    dropped: #{inspect(dropped)}  not in msgid: #{inspect(stray)}" end)}

             A dropped placeholder silently loses its value. One the msgid does not
             provide has no binding: Gettext logs an error and renders the literal
             `%{name}` text. Either way the page is wrong in this locale only —
             exactly where it is least likely to be noticed.
             """
    end
  end

  test "every locale's .po holds exactly its .pot template's msgids" do
    for domain <- domains_for(@source_locale) do
      pot = pot_path(domain)
      assert File.exists?(pot), "missing template #{Path.relative_to(pot, File.cwd!())}"
      template_ids = msgids(pot)

      for locale <- @locales do
        po_ids = msgids(po_path(locale, domain))
        missing = MapSet.difference(template_ids, po_ids)
        orphaned = MapSet.difference(po_ids, template_ids)

        assert MapSet.size(missing) == 0 and MapSet.size(orphaned) == 0,
               """
               #{domain}.po for #{locale} does not match #{domain}.pot:
                 missing (in the template, not the .po): #{Enum.map_join(missing, ", ", &describe/1)}
                 orphaned (in the .po, not the template): #{Enum.map_join(orphaned, ", ", &describe/1)}

               A missing msgid renders English; an orphaned one is dead text nothing
               renders or re-checks. Run `mix gettext.extract && mix gettext.merge
               priv/gettext` (errors.pot is hand-maintained — see CLAUDE.md).
               """
      end
    end
  end
end
