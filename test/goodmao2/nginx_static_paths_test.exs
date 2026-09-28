defmodule Goodmao2.NginxStaticPathsTest do
  @moduledoc """
  Ties the nginx template's serve-from-disk `location` regex to `Goodmao2Web.static_paths/0`.

  nginx answers the non-fingerprinted static paths from `priv/static` itself, so the request
  never reaches Phoenix. That is a performance choice, and it becomes a correctness one the
  moment a matched path stops being a file: `root` finds nothing and **nginx answers its own
  404** before the router is consulted. The application is correct, every test passes, and the
  path is dead in production only. Baudrate shipped exactly that for `robots.txt` (f37e344d).

  Both directions are held here:

  - every alternative in the regex names a path that `static_paths/0` ships in `priv/static`
    (the template named a `favicon.svg` that never existed — the SVG favicon is an inline
    `data:` URL in the root layout);
  - every root entry of `static_paths/0` is served by nginx — by that regex, or by the
    `location /assets/` block for the fingerprinted bundle — so a new root file is not
    silently proxied through the BEAM (CLAUDE.md: add it to *both*).
  """
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @template Path.join(@root, "ansible/roles/nginx/templates/goodmao2.conf.j2")
  @static_dir Path.join(@root, "priv/static")

  # Git-ignored build outputs (esbuild / Tailwind / phx.digest), absent from a fresh checkout
  # until the assets are built; every other static path must be committed.
  @built_outputs ~w(assets service_worker.js)

  # The static `location ~ ^/(…) {` block, captured up to its opening brace.
  @location_re ~r/location\s+~\s+\^\/\((?<alts>.+?)\)\s*\{/

  defp alternatives do
    case Regex.named_captures(@location_re, File.read!(@template)) do
      %{"alts" => alts} ->
        split_top_level(alts)

      nil ->
        flunk("""
        no static `location ~ ^/(…)` block found in #{@template}.

        If the block was restructured, update @location_re; do not delete this test.
        """)
    end
  end

  defp served, do: Enum.map(Goodmao2Web.static_paths(), &("/" <> &1))

  defp matches?(alt, path), do: Regex.match?(Regex.compile!("^/(?:" <> alt <> ")"), path)

  test "the static location block names something" do
    assert alternatives() != []
  end

  test "each alternative is one path, so each is checked on its own" do
    # A nested alternation such as `favicon[^/]*\.(ico|svg)` passes the check below as long as
    # *one* branch is real — which is how `favicon.svg` went unnoticed. One path per alternative.
    for alt <- alternatives() do
      refute alt =~ "|", "#{inspect(alt)} nests an alternation; split it into one per path"
    end
  end

  test "every alternative names a path static_paths/0 serves" do
    for alt <- alternatives() do
      assert Enum.any?(served(), &matches?(alt, &1)), """
      the nginx static block matches #{inspect(alt)}, but nothing in
      Goodmao2Web.static_paths/0 does:

        #{Enum.join(served(), "\n  ")}

      nginx serves this from disk with `root`, so it answers its own 404 and the request never
      reaches the router. If the path became a route, drop it from the regex in #{@template};
      if it is still a file, add it to static_paths/0.
      """
    end
  end

  test "every static path is a real file or directory in priv/static" do
    for path <- Goodmao2Web.static_paths(), path not in @built_outputs do
      assert File.exists?(Path.join(@static_dir, path)),
             "static_paths/0 names #{inspect(path)}, which priv/static does not ship"
    end
  end

  test "every static path is served by nginx, not proxied through the application" do
    template = File.read!(@template)

    assert template =~ ~r/location \/assets\/ \{/,
           "the template no longer serves the fingerprinted /assets/ bundle from disk"

    for path <- served(), path != "/assets" do
      assert Enum.any?(alternatives(), &matches?(&1, path)), """
      Goodmao2Web.static_paths/0 serves #{path}, but the nginx static `location` regex in
      #{@template} does not match it, so production proxies it through the BEAM.
      Add it to the regex.
      """
    end
  end

  # Splits an alternation on its top-level `|` only, so a character class or group stays in
  # one piece.
  defp split_top_level(alts) do
    alts
    |> String.graphemes()
    |> Enum.reduce({[], [], 0, 0, false}, &scan/2)
    |> close()
  end

  defp scan(char, {done, current, parens, brackets, escaped}) do
    cond do
      escaped -> {done, [char | current], parens, brackets, false}
      char == "\\" -> {done, [char | current], parens, brackets, true}
      char == "[" -> {done, [char | current], parens, brackets + 1, false}
      char == "]" -> {done, [char | current], parens, brackets - 1, false}
      char == "(" and brackets == 0 -> {done, [char | current], parens + 1, brackets, false}
      char == ")" and brackets == 0 -> {done, [char | current], parens - 1, brackets, false}
      char == "|" and parens == 0 and brackets == 0 -> {[finish(current) | done], [], 0, 0, false}
      true -> {done, [char | current], parens, brackets, false}
    end
  end

  defp close({done, current, _parens, _brackets, _escaped}) do
    [finish(current) | done]
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp finish(current), do: current |> Enum.reverse() |> Enum.join() |> String.trim()
end
