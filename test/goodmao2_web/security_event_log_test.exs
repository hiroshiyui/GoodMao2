defmodule Goodmao2Web.SecurityEventLogTest do
  @moduledoc """
  Security-relevant events leave a log line an operator can alert on — failed and throttled
  logins, second-factor failures and lockouts, factor and credential changes — and none of
  those lines carries the secret involved (password, code, or the attacker-chosen address).
  """
  # async: false — lifts the global log level to production's :info for the duration.
  use Goodmao2Web.ConnCase, async: false

  import ExUnit.CaptureLog
  import Goodmao2.AccountsFixtures

  alias Goodmao2.Accounts
  alias Goodmao2Web.UserAuth

  # Lift the suite's :warning to production's :info only while capturing, so fixture setup
  # outside the capture doesn't print.
  defp capture_info(fun) do
    capture_log([level: :info], fn ->
      previous = Logger.level()
      Logger.configure(level: :info)

      try do
        fun.()
      after
        Logger.configure(level: previous)
      end
    end)
  end

  test "a failed password login is logged without the address or password", %{conn: conn} do
    user = set_password(user_fixture())

    log =
      capture_info(fn ->
        post(conn, ~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => "hunter2-wrong"}
        })
      end)

    assert log =~ "auth.login_failed client="
    refute log =~ user.email
    refute log =~ "hunter2-wrong"
  end

  test "a wrong second factor is logged with the user and factor, not the code", %{conn: conn} do
    {user, secret} = totp_user_fixture()
    user = set_password(user)
    wrong = if NimbleTOTP.verification_code(secret) == "000000", do: "000001", else: "000000"

    log =
      capture_info(fn ->
        conn
        |> post(~p"/users/log-in", %{
          "user" => %{"email" => user.email, "password" => valid_user_password()}
        })
        |> post(~p"/users/two-factor/totp", %{"user" => %{"totp_code" => wrong}})
      end)

    assert log =~ "auth.second_factor_failed user_id=#{user.id} factor=totp"
    refute log =~ wrong
  end

  test "factor and credential changes are logged" do
    {user, _secret} = totp_user_fixture()

    log =
      capture_info(fn ->
        Accounts.generate_recovery_codes(user)
        {:ok, _} = Accounts.disable_totp(user)
      end)

    assert log =~ "accounts.recovery_codes_generated user_id=#{user.id}"
    assert log =~ "accounts.totp_disabled user_id=#{user.id}"
  end

  test "the logged client address is the proxy-set client, and can't smuggle fields" do
    forwarded = fn value ->
      build_conn() |> Plug.Conn.put_req_header("x-forwarded-for", value) |> UserAuth.client_ip()
    end

    assert forwarded.("203.0.113.9") == "203.0.113.9"
    assert forwarded.("2001:db8::1, 10.0.0.1") == "2001:db8::1"
    assert forwarded.("203.0.113.9 user_id=1") == "unparseable"
    assert UserAuth.client_ip(build_conn()) == "127.0.0.1"
  end
end
