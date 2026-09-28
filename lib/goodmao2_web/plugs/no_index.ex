defmodule Goodmao2Web.Plugs.NoIndex do
  @moduledoc """
  Tells search engines not to index a response or follow its links (`X-Robots-Tag: noindex,
  nofollow`).

  Plugged into the anonymous share endpoints (ADR-0004): the shared entry, the shared health
  report, and a shared entry's media. A share link is meant for the people it was sent to; once
  one leaks onto a crawlable page, the pet's health data would otherwise land in a search index
  and outlive the link's revocation or expiry there. A header rather than a `<meta>` tag, so it
  also covers the media bytes, and plugged at the controller rather than the action so the
  existence-hidden 404s carry it too.
  """
  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts), do: put_resp_header(conn, "x-robots-tag", "noindex, nofollow")
end
