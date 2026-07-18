defmodule Mix.Tasks.Goodmao.Doctor do
  @shortdoc "Preflight: verify the local dev prerequisites for GoodMao2"

  @moduledoc """
  Environment preflight / onboarding check for GoodMao2.

  Runs a series of defensive checks against the local development environment and
  prints one `PASS` / `WARN` / `FAIL` line per check, then a summary. The task exits
  non-zero only if a *hard* check FAILED — warnings never fail the run, they just flag
  things a new contributor probably wants to fix before `mix setup`.

  It mirrors the `doctor` verb from the original GoodMao CLI, adapted to this
  Elixir/Phoenix stack:

    * Runtime versions (Erlang/OTP + Elixir) against `.tool-versions` — WARN on mismatch.
    * PostgreSQL reachability using the configured `Goodmao2.Repo` credentials — FAIL if
      unreachable; the connecting role's `CREATEDB` privilege — WARN if absent.
    * Dependencies fetched (`mix deps.get`) — WARN if any look missing.
    * Asset installers (tailwind + esbuild) present — WARN if missing, advising
      `mix assets.setup`.
    * Production secrets (`SECRET_KEY_BASE`, `DATABASE_URL`) — only checked under
      `MIX_ENV=prod`; skipped/INFO in dev and test.

  Usage:

      mix goodmao.doctor

  This is a developer convenience tool. Its output is intentionally plain (not
  Gettext-scoped) and colorized with `IO.ANSI` when the terminal supports it.
  """

  use Mix.Task

  @requirements ["app.config"]

  @repo Goodmao2.Repo
  @tool_versions_file ".tool-versions"

  @impl Mix.Task
  def run(_args) do
    banner("GoodMao2 doctor — environment preflight")

    results =
      [
        check_runtime_versions(),
        check_postgres(),
        check_deps(),
        check_assets(),
        check_prod_secrets()
      ]
      |> List.flatten()

    IO.puts("")
    summarize(results)
  end

  # ── Check 1: Erlang/OTP + Elixir versions vs .tool-versions ──────────────────

  defp check_runtime_versions do
    guard(fn ->
      case read_tool_versions() do
        {:error, reason} ->
          [warn("runtime versions", "could not read #{@tool_versions_file}: #{reason}")]

        {:ok, pinned} ->
          [check_elixir_version(pinned), check_otp_version(pinned)]
      end
    end)
  end

  defp check_elixir_version(pinned) do
    current = System.version()

    case Map.get(pinned, "elixir") do
      nil ->
        info("elixir version", "no elixir pin in #{@tool_versions_file}; running #{current}")

      wanted ->
        if version_matches?(current, wanted) do
          pass("elixir version", "#{current} matches #{@tool_versions_file} (#{wanted})")
        else
          warn("elixir version", "running #{current}, #{@tool_versions_file} pins #{wanted}")
        end
    end
  end

  defp check_otp_version(pinned) do
    current = otp_release()

    case Map.get(pinned, "erlang") do
      nil ->
        info(
          "erlang/otp version",
          "no erlang pin in #{@tool_versions_file}; running OTP #{current}"
        )

      wanted ->
        wanted_major = wanted |> String.split(".") |> List.first()

        if current == wanted_major do
          pass("erlang/otp version", "OTP #{current} matches #{@tool_versions_file} (#{wanted})")
        else
          warn(
            "erlang/otp version",
            "running OTP #{current}, #{@tool_versions_file} pins #{wanted}"
          )
        end
    end
  end

  defp otp_release, do: List.to_string(:erlang.system_info(:otp_release))

  # A ".tool-versions" pin may be a bare version or "ref:...". Treat a leading-prefix
  # match as satisfying the pin (e.g. running 1.19.5 satisfies a 1.19 pin).
  defp version_matches?(current, wanted) do
    current == wanted or String.starts_with?(current, wanted <> ".") or
      String.starts_with?(wanted, current <> ".")
  end

  defp read_tool_versions do
    path = Path.join(File.cwd!(), @tool_versions_file)

    case File.read(path) do
      {:ok, contents} ->
        pinned =
          contents
          |> String.split("\n", trim: true)
          |> Enum.reject(&String.starts_with?(String.trim(&1), "#"))
          |> Enum.reduce(%{}, fn line, acc ->
            case String.split(String.trim(line), ~r/\s+/, parts: 2) do
              [tool, version] -> Map.put(acc, tool, String.trim(version))
              _ -> acc
            end
          end)

        {:ok, pinned}

      {:error, reason} ->
        {:error, :file.format_error(reason)}
    end
  end

  # ── Check 2: PostgreSQL reachability + CREATEDB privilege ────────────────────

  defp check_postgres do
    guard(fn ->
      config = Application.get_env(:goodmao2, @repo, [])

      case start_repo(config) do
        {:error, reason} ->
          [fail("postgres reachable", "could not start #{inspect(@repo)}: #{reason}")]

        {:ok, stop} ->
          try do
            reach = probe_postgres()
            reach_line = postgres_reach_line(reach)

            case reach do
              :ok -> [reach_line, check_createdb()]
              _ -> [reach_line]
            end
          after
            stop.()
          end
      end
    end)
  end

  # Start the repo with a small, fail-fast pool so an unreachable server surfaces
  # quickly instead of retrying forever. Returns a `stop/0` cleanup closure.
  #
  # We trap exits: if the DB is down, the repo supervisor may crash on start and,
  # because `start_link` links it here, that would otherwise take this task down.
  defp start_repo(config) do
    Enum.each([:ecto_sql, :postgrex], &Application.ensure_all_started/1)

    trap_was = Process.flag(:trap_exit, true)

    opts = Keyword.merge(config, pool_size: 1, queue_target: 500, queue_interval: 1000)

    case @repo.start_link(opts) do
      {:ok, pid} -> {:ok, fn -> stop_repo(pid, trap_was) end}
      {:error, {:already_started, _pid}} -> {:ok, fn -> restore_trap(trap_was) end}
      {:error, reason} -> restore_trap(trap_was) && {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp restore_trap(trap_was) do
    Process.flag(:trap_exit, trap_was)
    true
  end

  defp stop_repo(pid, trap_was) do
    if Process.alive?(pid), do: Supervisor.stop(pid)
    restore_trap(trap_was)
  rescue
    _ -> restore_trap(trap_was)
  catch
    _, _ -> restore_trap(trap_was)
  end

  defp probe_postgres do
    case Ecto.Adapters.SQL.query(@repo, "SELECT 1", [], log: false) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, db_error_message(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp postgres_reach_line(:ok), do: pass("postgres reachable", "SELECT 1 succeeded")

  defp postgres_reach_line({:error, msg}),
    do:
      fail(
        "postgres reachable",
        "#{msg} — is PostgreSQL running and seeded? (see config/dev.exs)"
      )

  defp check_createdb do
    case Ecto.Adapters.SQL.query(
           @repo,
           "SELECT rolcreatedb FROM pg_roles WHERE rolname = current_user",
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} ->
        pass("role can CREATEDB", "current DB role may create databases")

      {:ok, _} ->
        warn(
          "role can CREATEDB",
          "current DB role lacks CREATEDB — mix ecto.create/test setup will fail (ALTER ROLE goodmao2 CREATEDB)"
        )

      {:error, reason} ->
        warn("role can CREATEDB", "could not determine: #{db_error_message(reason)}")
    end
  rescue
    e -> [warn("role can CREATEDB", "could not determine: #{Exception.message(e)}")]
  catch
    :exit, reason -> warn("role can CREATEDB", "could not determine: #{inspect(reason)}")
  end

  defp db_error_message(%{postgres: %{message: message}}), do: message
  defp db_error_message(%{message: message}) when is_binary(message), do: message
  defp db_error_message(other), do: inspect(other)

  # ── Check 3: Dependencies fetched ────────────────────────────────────────────

  defp check_deps do
    guard(fn ->
      missing = missing_deps()

      cond do
        missing == :unknown ->
          [info("dependencies fetched", "could not inspect deps")]

        missing == [] ->
          [pass("dependencies fetched", "all declared deps are present")]

        true ->
          [
            warn(
              "dependencies fetched",
              "missing/unavailable: #{Enum.join(missing, ", ")} — run mix deps.get"
            )
          ]
      end
    end)
  end

  defp missing_deps do
    Mix.Dep.load_and_cache()
    |> Enum.reject(fn dep -> match?({:ok, _}, dep.status) end)
    |> Enum.map(& &1.app)
    |> Enum.uniq()
  rescue
    _ -> :unknown
  catch
    _, _ -> :unknown
  end

  # ── Check 4: Asset installers (tailwind + esbuild) ───────────────────────────

  defp check_assets do
    guard(fn ->
      [check_asset_tool("tailwind", Tailwind), check_asset_tool("esbuild", Esbuild)]
    end)
  end

  defp check_asset_tool(name, mod) do
    installed? =
      if Code.ensure_loaded?(mod) and function_exported?(mod, :bin_path, 0) do
        File.exists?(safe_bin_path(mod))
      else
        asset_binary_present?(name)
      end

    if installed? do
      pass("#{name} installed", "binary present for asset builds")
    else
      warn("#{name} installed", "binary missing — run mix assets.setup")
    end
  end

  defp safe_bin_path(mod) do
    mod.bin_path()
  rescue
    _ -> ""
  catch
    _, _ -> ""
  end

  # Fallback when the installer module isn't loaded: look for a cached binary.
  defp asset_binary_present?(name) do
    globs = [
      Path.join([File.cwd!(), "_build", "**", name <> "-*"]),
      Path.join([File.cwd!(), "_build", "**", name]),
      Path.join([System.user_home() || "", ".cache", "**", name <> "*"])
    ]

    Enum.any?(globs, fn glob -> Path.wildcard(glob) != [] end)
  end

  # ── Check 5: Production secrets (only meaningful under prod) ──────────────────

  defp check_prod_secrets do
    guard(fn ->
      if Mix.env() == :prod do
        [check_env_secret("SECRET_KEY_BASE"), check_env_secret("DATABASE_URL")]
      else
        [
          info(
            "production secrets",
            "skipped in #{Mix.env()} (only required with MIX_ENV=prod)"
          )
        ]
      end
    end)
  end

  defp check_env_secret(var) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" ->
        pass("env #{var}", "set")

      _ ->
        warn("env #{var}", "not set — required to boot in production")
    end
  end

  # ── Result plumbing ──────────────────────────────────────────────────────────

  # Wrap a check body so a raised/exited failure becomes a FAIL line instead of
  # crashing the whole task.
  defp guard(fun) do
    fun.()
  rescue
    e -> [fail("check", "unexpected error: #{Exception.message(e)}")]
  catch
    kind, reason -> [fail("check", "unexpected #{kind}: #{inspect(reason)}")]
  end

  defp pass(name, detail), do: emit(:pass, name, detail)
  defp warn(name, detail), do: emit(:warn, name, detail)
  defp fail(name, detail), do: emit(:fail, name, detail)
  defp info(name, detail), do: emit(:info, name, detail)

  defp emit(status, name, detail) do
    IO.puts([label(status), "  ", name, " — ", detail])
    status
  end

  defp label(:pass), do: colorize("PASS", :green)
  defp label(:warn), do: colorize("WARN", :yellow)
  defp label(:fail), do: colorize("FAIL", :red)
  defp label(:info), do: colorize("INFO", :cyan)

  defp summarize(results) do
    counts = Enum.frequencies(results)
    passed = Map.get(counts, :pass, 0)
    warned = Map.get(counts, :warn, 0)
    failed = Map.get(counts, :fail, 0)

    summary = "#{passed} passed, #{warned} warning(s), #{failed} failed"

    if failed > 0 do
      IO.puts(colorize("✖ #{summary}. Fix the FAIL items above before continuing.", :red))
      exit({:shutdown, 1})
    else
      IO.puts(colorize("✔ #{summary}. Ready to go.", :green))
    end
  end

  defp banner(text) do
    IO.puts(colorize(text, :bright))
    IO.puts("")
  end

  defp colorize(text, color) do
    if IO.ANSI.enabled?() do
      [ansi(color), text, :reset] |> IO.ANSI.format() |> IO.iodata_to_binary()
    else
      text
    end
  end

  defp ansi(:green), do: :green
  defp ansi(:yellow), do: :yellow
  defp ansi(:red), do: :red
  defp ansi(:cyan), do: :cyan
  defp ansi(:bright), do: :bright
end
