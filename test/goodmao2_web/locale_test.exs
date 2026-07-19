defmodule Goodmao2Web.LocaleTest do
  use Goodmao2Web.ConnCase, async: true

  alias Goodmao2Web.Locale

  describe "per-request locale resolution (Plugs.Locale)" do
    test "defaults to en with the English wordmark", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~s(<html lang="en")
      assert body =~ "GoodMao"
    end

    test "honours the Accept-Language header", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept-language", "ja,en-US;q=0.8")
        |> get(~p"/")
        |> html_response(200)

      assert body =~ ~s(<html lang="ja")
      # brand wordmark localizes per ADR-0002
      assert body =~ "グッドマオ"
    end

    test "the locale cookie wins over Accept-Language", %{conn: conn} do
      body =
        conn
        |> Plug.Test.put_req_cookie("locale", "zh_TW")
        |> put_req_header("accept-language", "ja")
        |> get(~p"/")
        |> html_response(200)

      assert body =~ ~s(<html lang="zh-Hant-TW")
      assert body =~ "顧毛"
    end
  end

  describe "phx.gen.auth LiveViews localize" do
    test "the log-in page renders in Japanese under an Accept-Language header", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept-language", "ja")
        |> get(~p"/users/log-in")
        |> html_response(200)

      assert body =~ "メールでログイン"
      refute body =~ "Log in with email"
    end

    test "the registration page renders in Traditional Chinese from the locale cookie", %{
      conn: conn
    } do
      body =
        conn
        |> Plug.Test.put_req_cookie("locale", "zh_TW")
        |> get(~p"/users/register")
        |> html_response(200)

      assert body =~ "註冊帳號"
      refute body =~ "Register for an account"
    end
  end

  describe "language switcher" do
    test "renders every shipped locale by its autonym", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~s(id="locale-switcher")
      assert body =~ "English"
      assert body =~ "台灣漢語"
      assert body =~ "日本語"
    end
  end

  describe "LocaleController.update/2" do
    test "persists the choice and returns to the referring page", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "http://www.example.com/pets")
        |> get(~p"/locale/zh_TW")

      assert redirected_to(conn) == "/pets"
      assert conn.resp_cookies["locale"].value == "zh_TW"
    end

    test "ignores an unknown locale and sets no cookie", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "http://www.example.com/")
        |> get(~p"/locale/klingon")

      assert redirected_to(conn) == "/"
      refute Map.has_key?(conn.resp_cookies, "locale")
    end

    test "never redirects off our host", %{conn: conn} do
      conn =
        conn
        |> put_req_header("referer", "http://evil.example.net/phish")
        |> get(~p"/locale/ja_JP")

      assert redirected_to(conn) == "/"
    end
  end

  describe "Locale.from_accept_language/1" do
    test "maps by primary subtag, honouring header order" do
      assert Locale.from_accept_language("ja") == "ja_JP"
      assert Locale.from_accept_language("zh-Hant-TW,zh;q=0.9") == "zh_TW"
      assert Locale.from_accept_language("en-US,en;q=0.9") == "en"
      assert Locale.from_accept_language("fr-FR,de;q=0.5") == nil
      assert Locale.from_accept_language(nil) == nil
    end
  end
end
