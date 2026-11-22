defmodule Goodmao2Web.SecurityHeadersTest do
  @moduledoc """
  The application owns the security headers on its own responses; nginx sets only HSTS
  (which it can, being the TLS terminator) plus whatever it serves itself off disk.

  Duplicates are not merely untidy: a browser honours the *first* header it sees, so a
  second copy silently decides policy. That is how HSTS lost `includeSubDomains` and
  fingerprinted assets lost `immutable` before 1.0.0. These tests pin the header set the
  proxy config is written against — if one moves back into nginx, the pair sends twice
  again and the weaker one wins.
  """
  use Goodmao2Web.ConnCase, async: true

  @headers [
    "x-frame-options",
    "x-content-type-options",
    "referrer-policy",
    "content-security-policy"
  ]

  test "a browser response carries each security header exactly once", %{conn: conn} do
    conn = get(conn, ~p"/")

    for header <- @headers do
      assert length(get_resp_header(conn, header)) == 1,
             "expected exactly one #{header}, got #{inspect(get_resp_header(conn, header))}"
    end
  end

  test "framing is refused by both the modern and the legacy header", %{conn: conn} do
    conn = get(conn, ~p"/")

    # Phoenix sends no X-Frame-Options of its own, leaning on `frame-ancestors`. nginx used
    # to supply it; now the app must, or removing it from the proxy would silently drop it.
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "form-action 'self'"
  end

  test "the application, not the proxy, sets nosniff and a referrer policy", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "referrer-policy") == ["strict-origin-when-cross-origin"]
  end

  # These leave through no pipeline: an unmatched path raises before any pipeline runs, and
  # /health has none. Before Plugs.BaselineSecurityHeaders they carried no security header at
  # all, and nginx adds only HSTS.
  for path <- ["/no-such-page", "/health"] do
    test "#{path} carries the baseline security headers once", %{conn: conn} do
      conn =
        try do
          get(conn, unquote(path))
        rescue
          e in Phoenix.Router.NoRouteError -> e.conn
        end

      for {header, value} <- Goodmao2Web.Plugs.BaselineSecurityHeaders.headers() do
        assert get_resp_header(conn, header) == [value], "#{unquote(path)}: #{header}"
      end
    end
  end

  test "a media 404 refuses framing in its CSP too, not only in X-Frame-Options", %{conn: conn} do
    # The :serve_media pipeline got Phoenix's default CSP, `frame-ancestors 'self'`, which a
    # CSP-aware browser obeys over `X-Frame-Options: DENY`. put_secure_browser_headers adds
    # that default only when no CSP is set yet, so the endpoint baseline now decides it.
    conn = get(conn, "/entries/shared/no-such-token/media/0")

    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "frame-ancestors 'none'"
  end
end
