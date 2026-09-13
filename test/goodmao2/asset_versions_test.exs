defmodule Goodmao2.AssetVersionsTest do
  # `assets/package.json` is never installed: it exists so Dependabot can see the frontend
  # toolchain, which is otherwise pinned where no dependency updater looks. A Dependabot PR
  # bumps only the manifest, so this test turns red until the real pin is moved with it.
  use ExUnit.Case, async: true

  @manifest Path.expand("../../assets/package.json", __DIR__)
  @daisyui Path.expand("../../assets/vendor/daisyui.js", __DIR__)

  setup_all do
    %{"devDependencies" => deps} = @manifest |> File.read!() |> Jason.decode!()
    %{deps: deps}
  end

  test "esbuild matches the version pinned in config/config.exs", %{deps: deps} do
    assert deps["esbuild"] == Application.fetch_env!(:esbuild, :version)
  end

  test "tailwindcss matches the version pinned in config/config.exs", %{deps: deps} do
    assert deps["tailwindcss"] == Application.fetch_env!(:tailwind, :version)
  end

  test "daisyui matches the vendored bundle (re-vendor assets/vendor/daisyui*.js)", %{
    deps: deps
  } do
    [_, vendored] = Regex.run(~r/var version = "([^"]+)"/, File.read!(@daisyui))
    assert deps["daisyui"] == vendored
  end
end
