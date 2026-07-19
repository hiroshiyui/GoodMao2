defmodule Goodmao2Web.Plugs.Locale do
  @moduledoc """
  Resolves the request locale — cookie → `Accept-Language` → default — and applies it:

    * sets it on the Gettext process for this (dead-view) request — the layout and root
      template read the active locale back via `Gettext.get_locale/1`,
    * mirrors it into the session so LiveViews can read it in `on_mount`
      (the persistent choice lives in the `locale` cookie, which survives session
      renewal on login/logout; this plug re-derives the session copy each request).

  Must run after `:fetch_session` in the `:browser` pipeline.
  """
  import Plug.Conn

  alias Goodmao2Web.Locale

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    locale = resolve(conn)

    Gettext.put_locale(Goodmao2Web.Gettext, locale)
    put_session(conn, :locale, locale)
  end

  defp resolve(conn) do
    cookie = conn.cookies[Locale.cookie()]

    cond do
      is_binary(cookie) and Locale.known?(cookie) ->
        cookie

      match = Locale.from_accept_language(List.first(get_req_header(conn, "accept-language"))) ->
        match

      true ->
        Locale.default()
    end
  end
end
