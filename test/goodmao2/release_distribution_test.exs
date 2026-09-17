defmodule Goodmao2.ReleaseDistributionTest do
  # A release's Erlang distribution admits whoever holds its cookie, and the cookie
  # `mix release` writes is readable by every account on the host (ADR-0021). These tests
  # render rel/env.sh.eex the way `mix release` does and source it with `sh`, as
  # bin/goodmao2 does, so the guard is exercised without building a release.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  @rel Path.expand("../../rel", __DIR__)
  @build_cookie "cookie-mix-release-wrote"
  @distributed ~w(start start_iex daemon daemon_iex remote rpc restart stop pid)

  setup %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "releases"))
    File.write!(Path.join([root, "releases", "COOKIE"]), @build_cookie)

    env_sh = Path.join(root, "env.sh")

    File.write!(
      env_sh,
      EEx.eval_file(Path.join(@rel, "env.sh.eex"), assigns: [release: %{name: :goodmao2}])
    )

    %{root: root, env_sh: env_sh}
  end

  # Sources env.sh with a clean slate for every variable it reads or sets, so nothing
  # leaks in from the environment running the suite.
  defp source(ctx, command, env \\ []) do
    base = [
      {"RELEASE_ROOT", ctx.root},
      {"RELEASE_COMMAND", command},
      {"RELEASE_COOKIE", nil},
      {"RELEASE_DISTRIBUTION", nil},
      {"RELEASE_NODE", nil},
      {"ERL_EPMD_ADDRESS", nil}
    ]

    System.cmd(
      "sh",
      [
        "-c",
        ~S|. "$1" && printf '%s %s %s' "$RELEASE_DISTRIBUTION" "$RELEASE_NODE" "$ERL_EPMD_ADDRESS"|,
        "sh",
        ctx.env_sh
      ],
      env: Enum.uniq_by(env ++ base, &elem(&1, 0)),
      stderr_to_stdout: true
    )
  end

  test "every command that joins the distribution refuses to run without RELEASE_COOKIE", ctx do
    for command <- @distributed do
      assert {output, 1} = source(ctx, command), "#{command} ran without a cookie"
      assert output =~ "RELEASE_COOKIE must be set"
    end
  end

  test "every command that joins the distribution refuses the cookie in releases/COOKIE", ctx do
    for command <- @distributed do
      assert {_output, 1} = source(ctx, command, [{"RELEASE_COOKIE", @build_cookie}]),
             "#{command} ran with the readable releases/COOKIE"
    end
  end

  test "with the server's cookie the node is named on, and epmd bound to, loopback", ctx do
    for command <- @distributed do
      assert {"name goodmao2@127.0.0.1 127.0.0.1", 0} =
               source(ctx, command, [{"RELEASE_COOKIE", "the-servers-own-secret-cookie"}])
    end
  end

  test "eval and version need no cookie, so bin/migrate keeps working", ctx do
    for command <- ~w(eval version) do
      assert {_output, 0} = source(ctx, command)
    end
  end

  test "RELEASE_DISTRIBUTION=none runs without a cookie", ctx do
    assert {"none " <> _, 0} = source(ctx, "start", [{"RELEASE_DISTRIBUTION", "none"}])
  end

  test "the node and the remote/rpc node both listen on 127.0.0.1 only" do
    for file <- ~w(vm.args.eex remote.vm.args.eex) do
      assert File.read!(Path.join(@rel, file)) =~
               ~r/^-kernel inet_dist_use_interface \{127,0,0,1\}$/m,
             "rel/#{file} does not bind distribution to loopback"
    end
  end
end
