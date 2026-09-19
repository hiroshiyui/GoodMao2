defmodule Goodmao2Web.SeleniumServer do
  @moduledoc """
  Auto-starts Selenium Server for browser tests.

  Multi-partition safe: the first partition to arrive starts the server,
  others detect it via health check.
  """

  # Not Selenium's default 4444: another checkout on this machine may already have a server
  # there, and a health check cannot tell whether that one was started with *this* project's
  # GeckoDriver on its PATH -- reusing it fails at session creation with "Unable to obtain:
  # geckodriver". Override with GOODMAO2_SELENIUM_PORT.
  @default_port 4445
  @poll_interval 500
  # A cold JVM on a CI runner can take well over 15 s to bring the standalone
  # server up; locally it is ready in a few seconds.
  @timeout 60_000

  # The CI image keeps Selenium and GeckoDriver in /opt/selenium
  # (GOODMAO2_SELENIUM_DIR); locally they come from `mix selenium.setup`.
  defp selenium_dir do
    System.get_env("GOODMAO2_SELENIUM_DIR") || Path.expand("../../tmp/selenium", __DIR__)
  end

  @doc """
  Ensures Selenium Server is running. Starts it if not already up.
  """
  def ensure_running do
    if server_ready?() do
      :ok
    else
      start_server()
      wait_for_ready(0)
    end
  end

  @doc "The port this project's Selenium server listens on."
  def port, do: String.to_integer(System.get_env("GOODMAO2_SELENIUM_PORT") || "#{@default_port}")

  @doc "The WebDriver endpoint Wallaby should talk to."
  def remote_url, do: "http://localhost:#{port()}/wd/hub/"

  defp server_ready? do
    :inets.start()
    :ssl.start()

    health_url = ~c"http://localhost:#{port()}/status"

    case :httpc.request(:get, {health_url, []}, [{:timeout, 2000}], []) do
      {:ok, {{_, 200, _}, _, body}} ->
        body_str = to_string(body)
        String.contains?(body_str, "\"ready\"") and String.contains?(body_str, "true")

      _ ->
        false
    end
  end

  defp start_server do
    jar_path = Path.join(selenium_dir(), Mix.Tasks.Selenium.Setup.selenium_jar_name())

    unless File.exists?(jar_path) do
      raise """
      Selenium Server JAR not found at #{jar_path}.
      Run `mix selenium.setup` to download it.
      """
    end

    # Set PATH to include geckodriver location
    current_path = System.get_env("PATH", "")
    env_path = ~c"#{selenium_dir()}:#{current_path}"

    log_path = Path.join(selenium_dir(), "server.log")

    Port.open(
      {:spawn_executable, System.find_executable("java")},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        # Selenium Grid has no authentication and binds every interface by
        # default, which would let anyone on the network drive a browser on
        # this machine; loopback is all the tests need.
        args: [
          "-jar",
          jar_path,
          "standalone",
          "--host",
          "127.0.0.1",
          "--port",
          "#{port()}",
          "--log",
          log_path
        ],
        env: [{~c"PATH", env_path}],
        cd: to_charlist(selenium_dir())
      ]
    )

    IO.puts("Starting Selenium Server (log: #{log_path})...")
  end

  defp wait_for_ready(elapsed) when elapsed >= @timeout do
    raise "Selenium Server did not become ready within #{@timeout}ms"
  end

  defp wait_for_ready(elapsed) do
    Process.sleep(@poll_interval)

    if server_ready?() do
      IO.puts("Selenium Server is ready.")
      :ok
    else
      wait_for_ready(elapsed + @poll_interval)
    end
  end
end
