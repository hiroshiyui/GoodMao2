defmodule Goodmao2Web.Features.AccessibilityTest do
  @moduledoc """
  The accessibility behaviour that only exists once JavaScript runs.

  The markup-level guarantees are asserted in the LiveView and component tests. What they
  cannot reach is the part a browser owns: the theme toggle's selected state is written by the
  inline script in `root.html.heex` (the choice lives in localStorage, so the server never
  knows it), and the skip link's usefulness is entirely about where focus lands.
  """
  use Goodmao2Web.FeatureCase, async: false

  @moduletag :feature

  defp pressed(session) do
    js_value(
      session,
      "return Object.fromEntries([...document.querySelectorAll('#theme-toggle [data-phx-theme]')].map(b => [b.dataset.phxTheme, b.getAttribute('aria-pressed')]))"
    )
  end

  feature "theme toggle reports which theme is selected", %{session: session} do
    session = visit(session, "/")

    # Nothing stored yet, so the app is following the system.
    assert pressed(session) == %{"system" => "true", "light" => "false", "dark" => "false"}

    session = click(session, Query.css("#theme-dark"))

    assert pressed(session) == %{"system" => "false", "light" => "false", "dark" => "true"}

    assert js_value(session, "return document.documentElement.getAttribute('data-theme')") ==
             "dark"
  end

  feature "the selected theme survives a live navigation", %{session: session} do
    user = browser_user_fixture()

    session =
      session
      |> log_in_via_browser(user)
      # Sign-in leaves a flash toast pinned over the top-right of the nav, where the theme
      # toggle is; re-visiting clears it rather than clicking blind through it.
      |> visit("/pets")
      |> click(Query.css("#theme-dark"))

    assert pressed(session)["dark"] == "true"

    # A LiveView patch re-renders the nav from the server, where every button says "false".
    # The script re-syncs on phx:page-loading-stop; without that the control would silently
    # go back to reporting nothing selected while still looking dark.
    session =
      session
      |> click(Query.css("#nav-notifications"))
      |> assert_has(Query.css("#notifications-heading"))

    assert pressed(session)["dark"] == "true"

    assert js_value(session, "return document.documentElement.getAttribute('data-theme')") ==
             "dark"
  end

  feature "the skip link is first in the tab order and moves focus to the main content",
          %{session: session} do
    user = browser_user_fixture()
    session = session |> log_in_via_browser(user) |> visit("/pets")

    # Reaching it must not mean tabbing through the nav it exists to skip, so it has to be the
    # document's first tab stop. (Wallaby 0.30's session-wide send_keys speaks a WebDriver
    # endpoint Selenium 4 removed, so the tab order is read from the DOM rather than typed.)
    first_tabbable =
      js_value(session, """
      const tabbable = [...document.querySelectorAll('a[href], button, input, select, textarea, [tabindex]')]
        .filter(el => !el.disabled && el.getAttribute('tabindex') !== '-1');
      return tabbable[0]?.id;
      """)

    assert first_tabbable == "skip-to-content"

    # Activating it must land focus on <main>, not merely scroll: a keyboard user who is not
    # moved is still in the nav, and the next Tab takes them back through it.
    session =
      execute_script(session, """
      const link = document.getElementById('skip-to-content');
      link.focus();
      link.click();
      """)

    assert js_value(session, "return document.activeElement.id") == "main-content",
           "activating the skip link left focus behind, so it skips nothing for a keyboard user"
  end
end
