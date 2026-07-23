defmodule Goodmao2Web.PWATest do
  @moduledoc """
  The installability contract for the app (ADR-free, but load-bearing): a browser only
  offers "Add to Home Screen" when the manifest, its icons, and a service worker with a
  fetch handler are all reachable. Each of those is a separate file that can silently stop
  being served -- a missing entry in `static_paths/0` returns 404 with no build error -- so
  they are asserted here rather than discovered on a phone.
  """
  use Goodmao2Web.ConnCase, async: true

  describe "web app manifest" do
    test "is served and declares an installable app", %{conn: conn} do
      conn = get(conn, ~p"/manifest.json")
      assert conn.status == 200

      manifest = Jason.decode!(conn.resp_body)

      # Chrome refuses to install without these.
      assert manifest["name"]
      assert manifest["short_name"]
      assert manifest["start_url"]
      assert manifest["display"] == "standalone"

      # An installed app should open where the user actually works, not the landing page.
      assert manifest["start_url"] == "/pets"
    end

    test "declares both any-purpose and maskable icons at the required sizes", %{conn: conn} do
      manifest = conn |> get(~p"/manifest.json") |> then(&Jason.decode!(&1.resp_body))
      icons = manifest["icons"]

      for purpose <- ~w(any maskable), size <- ~w(192x192 512x512) do
        assert Enum.any?(icons, &(&1["purpose"] == purpose and &1["sizes"] == size)),
               "manifest is missing a #{size} #{purpose} icon"
      end
    end

    test "every icon it points at is actually served", %{conn: conn} do
      manifest = conn |> get(~p"/manifest.json") |> then(&Jason.decode!(&1.resp_body))

      srcs =
        (manifest["icons"] ++ Enum.flat_map(manifest["shortcuts"] || [], &(&1["icons"] || [])))
        |> Enum.map(& &1["src"])
        |> Enum.uniq()

      assert srcs != []

      for src <- srcs do
        assert get(conn, src).status == 200, "manifest references #{src}, which is not served"
      end
    end
  end

  describe "install metadata in the document head" do
    test "links the manifest and the iOS-only icon and meta tags", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(rel="manifest")
      # iOS ignores the manifest entirely, so these are not redundant.
      assert html =~ ~s(rel="apple-touch-icon")
      assert html =~ ~s(name="apple-mobile-web-app-capable")
      assert html =~ ~s(name="mobile-web-app-capable")
      # Needed for the standalone app to draw into the notch area.
      assert html =~ "viewport-fit=cover"
    end
  end

  describe "service worker" do
    test "is served from the site root so its scope can be /", %{conn: conn} do
      conn = get(conn, ~p"/service_worker.js")
      assert conn.status == 200
      # A fetch handler is part of the installability criteria.
      assert conn.resp_body =~ "addEventListener(\"fetch\""
    end

    test "precaches an offline page, which is what makes Chrome offer to install", %{conn: conn} do
      body = conn |> get(~p"/service_worker.js") |> response(200)

      # Chrome will not show an install prompt unless the worker can answer a *navigation*
      # while offline; a bare fetch() passthrough silently fails that check.
      assert body =~ "/offline.html"
      assert body =~ "addEventListener(\"install\""
      assert body =~ ~s(mode!=="navigate") or body =~ ~s(mode !== "navigate")
    end

    test "serves the precached offline page as a self-contained static file", %{conn: conn} do
      conn = get(conn, ~p"/offline.html")

      assert conn.status == 200
      # It must render with no server, no session and no digested assets, so nothing may be
      # linked in from outside the file itself.
      refute conn.resp_body =~ ~s(<link)
      refute conn.resp_body =~ ~s(<script src)
    end
  end
end
