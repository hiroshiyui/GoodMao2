defmodule Goodmao2Web.Features.JsErrorsTest do
  @moduledoc """
  Walks every signed-in page in a real browser and fails on any JavaScript error.

  Nothing else in the suite runs the client. The app ships seven `phx-hook`s plus a service
  worker (`AvatarCropper`, `WeightChart`, `DisclosureState`, `TimezoneDetect`, `Clipboard`,
  `PushManager`, the reconnect-flash guard), and a hook that throws — or a `phx-hook` name
  that was never registered — leaves the whole suite green while the page is broken. LiveView
  reports an unknown hook through `console.error`, which is why that is recorded too.

  Errors thrown during the first load happen before a recorder can exist, so each page is
  re-mounted through a live navigation once the recorder is installed. A server-side crash
  throws nothing in the browser at all; it shows up as LiveView marking the view `phx-error`,
  which the mutation observer catches.
  """
  use Goodmao2Web.FeatureCase, async: false

  @moduletag :feature

  alias Goodmao2.PetsFixtures

  @recorder """
  if (!window.__jsErrors) {
    window.__jsErrors = [];
    const push = (kind, msg) => window.__jsErrors.push(kind + ": " + String(msg));
    window.addEventListener("error", (e) => push("error", e.message));
    window.addEventListener("unhandledrejection", (e) => push("rejection", e.reason));
    const original = console.error.bind(console);
    console.error = (...args) => { push("console.error", args.map(String).join(" ")); original(...args); };
    new MutationObserver((mutations) => {
      for (const m of mutations) {
        const el = m.target;
        if (el.classList && (el.classList.contains("phx-error") || el.classList.contains("phx-server-error"))) {
          push("liveview", "view crashed or disconnected (" + (el.id || el.tagName) + ")");
        }
      }
    }).observe(document.documentElement, {attributes: true, attributeFilter: ["class"], subtree: true});
  }
  """

  @remount """
  const main = document.querySelector("[data-phx-main]");
  if (main) {
    const a = document.createElement("a");
    a.href = location.pathname + location.search;
    a.setAttribute("data-phx-link", "redirect");
    a.setAttribute("data-phx-link-state", "replace");
    a.hidden = true;
    main.appendChild(a);
    a.click();
  }
  """

  # Opens each disclosure and clicks each in-page toggle, so hooks that only mount behind a
  # collapsed <details> (the QuickLog extras, the medication forms) actually run.
  @exercise """
  document.querySelectorAll("details:not([open])").forEach((d) => { d.open = true; });
  document.querySelectorAll("[role=group] button[aria-pressed=false]").forEach((b) => b.click());
  """

  setup do
    user = browser_user_fixture()
    pet = PetsFixtures.pet_fixture(user, %{"name" => "Mochi", "weight_unit" => "kilograms"})

    entry =
      PetsFixtures.log_entry_fixture(user, pet, %{
        "type" => "weight",
        "data" => %{"weight_grams" => 4200}
      })

    %{
      user: user,
      paths: [
        "/pets",
        "/pets/new",
        "/pets/past",
        "/pets/#{pet.id}",
        "/pets/#{pet.id}/edit",
        "/pets/#{pet.id}/access",
        "/pets/#{pet.id}/end-of-care",
        "/pets/#{pet.id}/reports",
        "/pets/#{pet.id}/medications",
        "/pets/#{pet.id}/logs/#{entry.id}",
        "/messages",
        "/notifications",
        "/users/settings",
        "/users/settings/password",
        "/users/vet-profile"
      ]
    }
  end

  feature "signed-in pages run without JavaScript errors", %{
    session: session,
    user: user,
    paths: paths
  } do
    session = log_in_via_browser(session, user)
    assert crawl(session, paths) == []
  end

  feature "guest pages run without JavaScript errors", %{session: session} do
    assert crawl(session, ["/", "/users/log-in", "/users/register"]) == []
  end

  defp crawl(session, paths) do
    Enum.flat_map(paths, fn path ->
      session = visit(session, path)

      # A redirect would mean crawling a different page than the one named.
      assert current_path(session) == URI.parse(path).path,
             "#{path} redirected to #{current_path(session)}"

      session
      |> execute_script(@recorder)
      |> execute_script(@remount)

      # Let the live navigation land and the hooks mount again.
      Process.sleep(700)

      session
      |> execute_script(@recorder)
      |> execute_script(@exercise)

      Process.sleep(400)

      session
      |> js_value("return window.__jsErrors || []")
      |> Enum.map(&"#{path} — #{&1}")
    end)
  end
end
