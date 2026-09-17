defmodule Goodmao2Web.RequestLoggingTest do
  @moduledoc """
  Magic-link, email-confirmation, and share-link tokens are live credentials that travel in the
  URL path, and second-factor codes travel as params. None of them may reach the production
  log, which is kept at `:info` — so a token-bearing request line logs below it and the params
  are filtered.
  """
  use Goodmao2Web.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Goodmao2Web.Endpoint

  test "requests carrying a token in the path log below production's :info" do
    for path <- [
          ~w(users log-in SECRETTOKEN),
          ~w(users settings confirm-email SECRETTOKEN),
          ~w(entries shared SECRETTOKEN),
          ~w(entries shared SECRETTOKEN media 1),
          ~w(reports shared SECRETTOKEN)
        ] do
      assert Endpoint.request_log_level(%Plug.Conn{path_info: path}) == :debug
    end

    for path <- [~w(), ~w(users log-in), ~w(pets 1), ~w(media 1)] do
      assert Endpoint.request_log_level(%Plug.Conn{path_info: path}) == :info
    end
  end

  test "a shared-link request writes no token at :info", %{conn: conn} do
    # The suite runs at :warning; lift it to production's level for just this request.
    log =
      capture_log([level: :info], fn ->
        previous = Logger.level()
        Logger.configure(level: :info)

        try do
          get(conn, "/reports/shared/SECRETTOKEN123")
        after
          Logger.configure(level: previous)
        end
      end)

    refute log =~ "SECRETTOKEN123"
  end

  test "token and second-factor params are filtered" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "user" => %{"token" => "t", "totp_code" => "123456", "recovery_code" => "abcd"},
        "_csrf_token" => "c"
      })

    assert filtered == %{
             "user" => %{
               "token" => "[FILTERED]",
               "totp_code" => "[FILTERED]",
               "recovery_code" => "[FILTERED]"
             },
             "_csrf_token" => "[FILTERED]"
           }
  end
end
