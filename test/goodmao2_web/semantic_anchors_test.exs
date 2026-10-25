defmodule Goodmao2Web.SemanticAnchorsTest do
  @moduledoc """
  Gate for the parts of the semantic-anchor rule that can be falsified.

  CLAUDE.md: "Every meaningful template element carries a stable semantic `id`/`class` (loop
  items derive an id from the record)". The headline half is a judgement ("meaningful"
  excludes presentational wrappers and leaf components) and stays review-held. What is
  falsifiable is **uniqueness**, and the rule that stylesheets hang off semantic selectors:

    * a `:for` element with a literal `id` renders that id once per item;
    * a rendered page carries no duplicate `id` (`aria-labelledby`, `for`/`id` and LiveView
      patching all resolve by it, and a duplicate silently binds the wrong one);
    * `app.css` targets semantic classes, not structure or position.

  Duplicates are checked against **rendered output**, never by counting literals in a
  template: two complementary `:if` branches may legitimately share an id. Ported from
  Baudrate's `semantic_anchors_test.exs` (its ADR 0018).
  """
  use Goodmao2Web.ConnCase, async: true

  @web_root "lib/goodmao2_web"
  @app_css "assets/css/app.css"

  # Every parameterless page a guest can reach.
  @public_pages ["/", "/users/log-in", "/users/register"]

  # Every parameterless page a signed-in member can reach.
  @member_pages [
    "/pets",
    "/pets/new",
    "/pets/past",
    "/messages",
    "/notifications",
    "/users/settings",
    "/users/settings/password",
    "/users/settings/two-factor",
    "/users/vet-profile"
  ]

  # Selectors in app.css that chain structural classes deliberately. Each restyles a daisyUI
  # *component* generically rather than one meaningful element. A new entry here is a
  # decision, which is the point of listing them.
  @structural_exemptions []

  describe "uniqueness" do
    test "a :for element never carries a literal id" do
      offenders =
        template_files()
        |> Enum.flat_map(fn path ->
          source = File.read!(path)

          for {tag, offset} <- tags(source),
              String.contains?(tag, ":for="),
              [_, value] = Regex.run(~r/\sid="([^"]*)"/, tag) || [nil, nil],
              is_binary(value),
              not String.contains?(value, "\#{") do
            "#{path}:#{line_of(source, offset)} id=\"#{value}\""
          end
        end)

      assert offenders == [],
             """
             A `:for` element with a fixed `id` renders that id once per item, so the page
             has as many duplicates as the list is long. Derive it from the record
             (`id={"thing-\#{thing.id}"}`) and keep the shared class for styling.

             #{Enum.join(offenders, "\n")}
             """
    end

    test "no guest page renders a duplicate id", %{conn: conn} do
      for path <- @public_pages, do: assert_unique_ids(conn, path)
    end

    test "no member page renders a duplicate id", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      for path <- @member_pages, do: assert_unique_ids(conn, path)
    end
  end

  describe "stylesheets target semantic selectors" do
    test "app.css adds no structural or positional selector" do
      found =
        @app_css
        |> File.read!()
        |> strip_comments()
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.filter(fn line ->
          String.contains?(line, "> .") or String.contains?(line, ":nth-child(") or
            String.contains?(line, ":nth-of-type(")
        end)
        |> Enum.map(&String.trim_trailing(&1, ","))
        |> Enum.map(&String.trim_trailing(&1, " {"))
        |> Enum.reject(&(&1 in @structural_exemptions))

      assert found == [],
             """
             app.css gained a structural or positional selector (`.card > .card-body`,
             `:nth-child`). Give the element a semantic handle first and target that.

             If the rule genuinely targets a daisyUI *component* rather than one meaningful
             element, add it to @structural_exemptions with a comment saying which, so the
             decision is visible rather than absorbed.

             #{Enum.join(found, "\n")}
             """
    end
  end

  # --- helpers ---

  defp assert_unique_ids(conn, path) do
    conn = get(conn, path)

    assert conn.status == 200,
           "#{path} answered #{conn.status}. This list is the gate's coverage — fix the " <>
             "path or remove it deliberately, do not let it rot."

    dups =
      ~r/\sid="([^"]+)"/
      |> Regex.scan(html_response(conn, 200), capture: :all_but_first)
      |> List.flatten()
      |> Enum.frequencies()
      |> Enum.filter(fn {_id, n} -> n > 1 end)
      |> Enum.sort()

    assert dups == [],
           "#{path} renders duplicate ids: #{inspect(dups)}. An `id` must be unique per " <>
             "rendered page — `aria-labelledby`, `for`/`id` and LiveView patching all " <>
             "resolve by it, and a duplicate silently binds the wrong one."
  end

  defp template_files do
    Path.wildcard(Path.join(@web_root, "**/*.{ex,heex}"))
  end

  # Opening tags, with their byte offset, so a failure can name a line.
  defp tags(source) do
    Regex.scan(~r/<[.\w][^>]*?>/s, source, return: :index)
    |> Enum.map(fn [{start, len} | _] -> {binary_part(source, start, len), start} end)
  end

  defp line_of(source, offset) do
    source
    |> binary_part(0, offset)
    |> String.graphemes()
    |> Enum.count(&(&1 == "\n"))
    |> Kernel.+(1)
  end

  defp strip_comments(css), do: Regex.replace(~r|/\*.*?\*/|s, css, "")
end
