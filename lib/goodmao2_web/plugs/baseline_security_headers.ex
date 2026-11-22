defmodule Goodmao2Web.Plugs.BaselineSecurityHeaders do
  @moduledoc """
  The security headers every response the router answers starts with.

  The application owns its response headers; nginx adds only HSTS. The `:browser` and
  `:serve_media` pipelines and the media controllers each set their own, but a response that
  leaves through no pipeline carried none at all: the 404 for a path no route matches (raised
  before any pipeline runs) and `/health`. Set in the endpoint just before the router, so the
  pipelines and controllers that set a header of their own simply overwrite it, and every
  other response still has one copy.

  It also decides the `:serve_media` pipeline's CSP for its redirects and 404s:
  `put_secure_browser_headers/2` adds Phoenix's default policy (`frame-ancestors 'self'`,
  which a CSP-aware browser obeys over `X-Frame-Options: DENY`) only when none is set yet.

  After `Plug.Static`, not before: a `default-src 'none'` policy on `service_worker.js`, served
  by `Plug.Static` when nginx is not in front, would govern the worker itself.

  The policy is the strictest one: these responses are plain text or JSON and load nothing.
  """
  import Plug.Conn

  @headers [
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"referrer-policy", "strict-origin-when-cross-origin"},
    {"content-security-policy", "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"}
  ]

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts), do: merge_resp_headers(conn, @headers)

  @doc "The baseline header set, for tests."
  def headers, do: @headers
end
