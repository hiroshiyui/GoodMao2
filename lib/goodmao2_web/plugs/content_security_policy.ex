defmodule Goodmao2Web.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets a Content-Security-Policy header on browser responses and threads a
  per-request nonce through to the layout.

  The policy is deliberately tight for a LiveView + Tailwind/daisyUI monolith
  where everything is served same-origin:

    * `script-src 'self' 'nonce-…'` — the bundled `app.js` is same-origin; the one
      inline `<script>` (the pre-paint theme setter in `root.html.heex`) carries the
      per-request nonce. No other inline scripts exist.
    * `style-src 'self' 'unsafe-inline'` — the compiled stylesheet is same-origin;
      `'unsafe-inline'` covers the inline `style` attributes LiveView/topbar set at
      runtime (nonces can't apply to style *attributes*).
    * `connect-src 'self'` — the LiveView websocket and long-poll fallback are
      same-origin (CSP treats `'self'` as matching same-origin `ws`/`wss`).
    * `img-src 'self' data:` — same-origin images plus the inline SVG favicon.

  The nonce is exposed as `conn.assigns.csp_nonce` so the root layout can stamp it
  onto the inline script (`nonce={assigns[:csp_nonce]}`); it is regenerated per
  request and never reused.
  """
  import Plug.Conn

  @doc false
  def init(opts), do: opts

  @doc false
  def call(conn, _opts) do
    nonce = generate_nonce()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp generate_nonce do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "base-uri 'self'",
        "frame-ancestors 'self'",
        "object-src 'none'",
        "img-src 'self' data:",
        "font-src 'self'",
        "style-src 'self' 'unsafe-inline'",
        "connect-src 'self'",
        "script-src 'self' 'nonce-#{nonce}'"
      ],
      "; "
    )
  end
end
