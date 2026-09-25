defmodule Goodmao2.RuntimeVersionsTest do
  # `.tool-versions` is the one Erlang/Elixir pin. Dev reads it through asdf, CI through
  # setup-beam's `version-file`, and production through Ansible's group_vars lookup (to
  # provision) and the release commit's own copy (to build). Anything that states a version
  # itself is a second copy that drifts, so this test fails when one appears or goes stale.
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)

  defp read!(path), do: @root |> Path.join(path) |> File.read!()

  setup_all do
    pins =
      ".tool-versions"
      |> read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split/1)
      |> Map.new(fn [tool, version | _] -> {tool, version} end)

    %{erlang: Map.fetch!(pins, "erlang"), elixir: Map.fetch!(pins, "elixir")}
  end

  test "Elixir is pinned to its build for the pinned OTP major", %{erlang: erlang, elixir: elixir} do
    [otp_major | _] = String.split(erlang, ".")
    assert elixir =~ ~r/-otp-#{otp_major}\z/
  end

  test "the running runtime is the pinned one", %{erlang: erlang, elixir: elixir} do
    otp_major = List.to_string(:erlang.system_info(:otp_release))
    otp_version = [:code.root_dir(), "releases", otp_major, "OTP_VERSION"] |> Path.join()

    assert otp_version |> File.read!() |> String.trim() == erlang
    assert System.version() == String.replace(elixir, ~r/-otp-\d+\z/, "")
  end

  test "every CI setup-beam step reads .tool-versions strictly" do
    ci = read!(".github/workflows/ci.yml")
    steps = String.split(ci, "uses: erlef/setup-beam@") |> tl()

    assert steps != []

    for step <- steps do
      [with_block | _] = String.split(step, ~r/\n\s*- (name|uses|run):/, parts: 2)
      assert with_block =~ ~r/version-file: \.tool-versions\b/
      assert with_block =~ ~r/version-type: strict\b/
    end

    refute ci =~ ~r/(otp|elixir)-version:/

    # A floating runner label changes the OS under a fixed .tool-versions pin, and
    # builds.hex.pm may have no build for it yet.
    refute ci =~ ~r/runs-on:\s*ubuntu-latest/
  end

  test "Ansible provisions from .tool-versions instead of its own copy" do
    vars = read!("ansible/inventory/group_vars/all.yml")

    assert vars =~ ~r/lookup\('ansible\.builtin\.file', [^)]*\.tool-versions'\)/

    for var <- ~w(erlang_version elixir_version) do
      [_, value] = Regex.run(~r/^#{var}: (.+)$/m, vars)
      assert value =~ "tool_version_pins", "#{var} must derive from .tool-versions, got #{value}"
    end
  end

  test "the docs name the pinned versions", %{erlang: erlang, elixir: elixir} do
    [otp_major | _] = String.split(erlang, ".")
    elixir_minor = elixir |> String.split(".") |> Enum.take(2) |> Enum.join(".")

    assert read!("doc/deployment.md") =~ "**Erlang #{erlang}**, **Elixir #{elixir}**"
    assert read!("ansible/README.md") =~ "Erlang #{erlang} + Elixir #{elixir}"
    assert read!("README.md") =~ "developed on Elixir #{elixir_minor} / OTP #{otp_major}"
  end
end
