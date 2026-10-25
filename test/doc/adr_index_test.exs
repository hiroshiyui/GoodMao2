defmodule Doc.AdrIndexTest do
  @moduledoc """
  The ADR index in `doc/adr/README.md` is the only thing most readers see.

  A record's Status line is the authoritative statement of what happened to it; the index
  row is a summary of that line, and a summary is allowed to be shorter. What it is not
  allowed to do is lose the pointer: a row that says `Accepted` while the record says
  `Superseded by ADR-0042` hands the reader the reversed answer and no way to find the
  reversal. The same goes the other way: a row naming an ADR the record itself does not
  mention is a claim nobody maintained.

  So the invariant is not textual equality but:

    * the index lists exactly the records on disk (the two deliberately skipped numbers,
      0006 and 0010, are struck-through rows with no file and are listed in `@skipped`);
    * a row references exactly the ADRs its record's Status references;
    * where the Status uses a relationship verb, the row uses it too;
    * every `[NNNN](file)` link resolves to the record it names.

  Ported from Baudrate's `adr_index_test.exs`, where the drift it catches had sat unseen
  through a release.
  """

  use ExUnit.Case, async: true

  @adr_dir "doc/adr"
  @index Path.join(@adr_dir, "README.md")

  # Numbers the index documents as skipped (see its "Provenance" section). They have a
  # struck-through row and no record.
  @skipped ["0006", "0010"]

  @verbs ["superseded", "deprecated", "amended"]

  defp records do
    Path.wildcard(Path.join(@adr_dir, "[0-9][0-9][0-9][0-9]-*.md"))
    # 0000 is the template, not a decision.
    |> Enum.reject(&String.starts_with?(Path.basename(&1), "0000-"))
    |> Map.new(fn path -> {Path.basename(path) |> String.slice(0, 4), File.read!(path)} end)
  end

  defp index_rows do
    Regex.scan(
      ~r/^\|\s*\[(\d{4})\]\([^)]+\)\s*\|[^|]*\|\s*(.+?)\s*\|\s*$/m,
      File.read!(@index)
    )
    |> Map.new(fn [_, number, status] -> {number, status} end)
  end

  defp skipped_rows do
    Regex.scan(~r/^\|\s*~~(\d{4})~~\s*\|/m, File.read!(@index))
    |> Enum.map(fn [_, number] -> number end)
  end

  # Everything between `- **Status:**` and the next `- **` field (or a blank line).
  defp status_line(body) do
    case Regex.run(~r/^- \*\*Status:\*\*\s*(.+?)(?=^- \*\*|\n\s*\n)/ms, body) do
      [_, status] -> status |> String.split() |> Enum.join(" ")
      nil -> nil
    end
  end

  # ADR numbers named as `ADR-0042`, `[0042](…)` or a bare 4-digit `0042`.
  defp referenced_adrs(text) do
    ~r/(?:ADR-|\[)?\b(\d{4})\b/
    |> Regex.scan(text)
    |> MapSet.new(fn [_, number] -> number end)
  end

  defp verbs_in(text) do
    downcased = String.downcase(text)
    MapSet.new(Enum.filter(@verbs, &String.contains?(downcased, &1)))
  end

  test "every record has an index row, and every row a record" do
    records = MapSet.new(Map.keys(records()))
    rows = MapSet.new(Map.keys(index_rows()))

    assert MapSet.difference(records, rows) |> MapSet.to_list() == [],
           "ADRs on disk with no row in #{@index}"

    assert MapSet.difference(rows, records) |> MapSet.to_list() == [],
           "rows in #{@index} naming no ADR on disk"

    assert Enum.sort(skipped_rows()) == Enum.sort(@skipped),
           "the struck-through rows in #{@index} are not the documented skips #{inspect(@skipped)}"

    assert MapSet.disjoint?(records, MapSet.new(@skipped)),
           "a skipped number has grown a record; drop it from @skipped and the Provenance note"
  end

  test "every record has a Status line" do
    missing = for {number, body} <- records(), is_nil(status_line(body)), do: number
    assert missing == [], "ADRs with no parseable `- **Status:**` field: #{inspect(missing)}"
  end

  test "an index row references exactly the ADRs its record's Status does" do
    rows = index_rows()

    drift =
      for {number, body} <- records(),
          status = status_line(body),
          status != nil,
          row = Map.get(rows, number, ""),
          in_record = referenced_adrs(status),
          in_row = referenced_adrs(row),
          not MapSet.equal?(in_record, in_row) do
        {number, MapSet.to_list(MapSet.difference(in_record, in_row)),
         MapSet.to_list(MapSet.difference(in_row, in_record))}
      end

    assert drift == [], """
    Index rows disagree with their record's Status line about which ADRs it refers to.
    Each entry is {ADR, missing from the row, extra in the row}:

    #{inspect(drift, pretty: true)}

    The row may abbreviate the Status line, but it must keep every ADR number the
    record points at.
    """
  end

  test "an index row keeps the relationship verb its record's Status uses" do
    rows = index_rows()

    drift =
      for {number, body} <- records(),
          status = status_line(body),
          status != nil,
          row = Map.get(rows, number, ""),
          dropped = MapSet.difference(verbs_in(status), verbs_in(row)),
          not Enum.empty?(dropped) do
        {number, MapSet.to_list(dropped)}
      end

    assert drift == [], """
    Index rows drop a relationship verb their record's Status line uses:

    #{inspect(drift, pretty: true)}

    "superseded"/"deprecated"/"amended" is what tells a reader whether the decision still
    holds.
    """
  end

  test "every ADR link in a record or the index resolves to that record's file" do
    sources = Map.put(records(), "README.md", File.read!(@index))

    broken =
      for {source, text} <- sources,
          [_, number, href] <- Regex.scan(~r/\[(\d{4})\]\(([^)]+)\)/, text),
          not (String.starts_with?(href, "#") or href =~ ~r{^[a-z]+://}),
          reason = link_problem(number, href),
          reason != nil,
          do: {source, "[#{number}](#{href})", reason}

    assert broken == [], """
    ADR links that do not resolve to the record they name:

    #{inspect(broken, pretty: true)}
    """
  end

  defp link_problem(number, href) do
    path = Path.join(@adr_dir, href)

    cond do
      not File.exists?(path) -> :no_such_file
      not String.starts_with?(Path.basename(href), number <> "-") -> :wrong_record
      true -> nil
    end
  end

  test "no accepted record is still marked Proposed in the index, or vice versa" do
    rows = index_rows()

    drift =
      for {number, body} <- records(),
          status = status_line(body),
          status != nil,
          row = Map.get(rows, number, ""),
          head = fn text -> text |> String.split(~r/[\s_(]/, parts: 2) |> hd() end,
          head.(status) != head.(row) do
        {number, status, row}
      end

    assert drift == [], """
    Index rows whose leading status word differs from their record's:

    #{inspect(drift, pretty: true)}
    """
  end
end
