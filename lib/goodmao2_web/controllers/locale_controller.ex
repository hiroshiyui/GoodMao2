defmodule Goodmao2Web.LocaleController do
  use Goodmao2Web, :controller

  alias Goodmao2Web.Locale

  @one_year 60 * 60 * 24 * 365

  @doc """
  Persists the chosen locale in the `locale` cookie and returns the user to the page
  they switched from. Unknown locales are ignored (cookie left untouched). A full
  navigation follows, so the new locale takes effect for the dead render, every
  LiveView `on_mount`, and the `<html lang>` attribute.
  """
  def update(conn, %{"locale" => locale}) do
    conn =
      if Locale.known?(locale) do
        put_resp_cookie(conn, Locale.cookie(), locale,
          max_age: @one_year,
          same_site: "Lax",
          http_only: true,
          # Stamp Secure whenever the request arrived over TLS (always in prod via force_ssl).
          secure: conn.scheme == :https
        )
      else
        conn
      end

    redirect(conn, to: referer_path(conn))
  end

  # Only ever redirect to a path on our own host (never an absolute/off-site URL).
  defp referer_path(conn) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{host: host, path: path} when is_binary(path) <- URI.parse(referer),
         true <- host == conn.host do
      path
    else
      _ -> ~p"/"
    end
  end
end
