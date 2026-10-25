defmodule Goodmao2Web.Features.LayoutTest do
  @moduledoc """
  Checks rendered layout in both themes at a narrow and a desktop width: no page scrolls
  sideways, and every dropdown menu opens inside the viewport with each item reachable.

  The narrow width is Firefox's minimum window, 500 px (a 488 px viewport): Firefox refuses
  anything smaller. It is below Tailwind's first breakpoint (640 px), so it renders the phone
  layout, though a 360 px phone has less room still.

  Pixel screenshots break with every browser update, so these are geometric assertions
  instead, aimed at what a Tailwind or vendored daisyUI bump breaks without any test noticing:
  a long unbreakable token (a pet name, a note) widening the page, and a theme clipping a menu
  so its items cannot be clicked. An item is reachable when `elementFromPoint` at its centre
  lands inside the menu, which fails for clipped and covered items alike. Ported from
  Baudrate's `layout_test.exs`.
  """
  use Goodmao2Web.FeatureCase, async: false

  @moduletag :feature
  # Each feature checks every page in two themes at two widths.
  @moduletag timeout: 600_000

  alias Goodmao2.PetsFixtures

  # `data-theme` carries the stored preference verbatim (root.html.heex).
  @themes ["light", "dark"]
  @sizes [narrow: {500, 844}, desktop: {1280, 900}]

  # Returns the page's horizontal overflow, naming the innermost elements that stick out
  # (elements inside a scrolling or clipping container are allowed).
  @overflow """
  const vw = document.documentElement.clientWidth;
  const describe = (el) => el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") +
    (typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\\s+/).slice(0, 2).join(".") : "");
  if (document.documentElement.scrollWidth <= vw + 1) return [];
  const contained = (el) => {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      if (["auto", "scroll", "hidden", "clip"].includes(getComputedStyle(p).overflowX)) return true;
    }
    return false;
  };
  const sticksOut = [...document.body.querySelectorAll("*")].filter((el) => {
    if (contained(el)) return false;
    const r = el.getBoundingClientRect();
    if (r.width > 0 && r.right > vw + 1) return true;
    return getComputedStyle(el).overflowX === "visible" && el.scrollWidth > el.clientWidth + 1 &&
      r.left + el.scrollWidth > vw + 1;
  });
  const innermost = sticksOut.filter((el) => !sticksOut.some((o) => o !== el && el.contains(o)));
  return ["page is " + document.documentElement.scrollWidth + "px wide in a " + vw + "px window: " +
    innermost.slice(0, 4).map(describe).join(", ")];
  """

  # Opens every visible dropdown in turn and records menus that stick out of the viewport or
  # have items another element covers or clips. Results land in window.__menuProblems.
  # The app's dropdowns are all <details> disclosures (the hamburger nav, the locale
  # switcher), which the browser opens by itself.
  @menus """
  window.__menuProblems = null;
  (async () => {
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const vw = document.documentElement.clientWidth;
    const describe = (el) => el.tagName.toLowerCase() + (el.id ? "#" + el.id : "") +
      (typeof el.className === "string" && el.className.trim() ? "." + el.className.trim().split(/\\s+/).slice(0, 2).join(".") : "");
    // Scroll only the window: scrollIntoView also scrolls an overflow: hidden ancestor,
    // which would reveal exactly the clipped items being looked for.
    const centre = async (el) => {
      const r = el.getBoundingClientRect();
      if (r.top < 100 || r.bottom > window.innerHeight - 100) {
        window.scrollBy(0, r.top + r.height / 2 - window.innerHeight / 2);
        await sleep(50);
      }
    };
    const problems = [];
    const triggers = [...document.querySelectorAll(".dropdown > [aria-haspopup], details.dropdown > summary")]
      .filter((t) => t.getClientRects().length > 0);
    for (const trigger of triggers) {
      const root = trigger.closest(".dropdown");
      const menu = root.querySelector(".dropdown-content");
      if (!menu) continue;
      const disclosure = root.tagName === "DETAILS" ? root : null;
      await centre(trigger);
      if (disclosure) { disclosure.open = true; } else { trigger.focus(); }
      await sleep(200);
      const r = menu.getBoundingClientRect();
      if (r.width === 0 || getComputedStyle(menu).visibility === "hidden") {
        problems.push(describe(trigger) + ": menu did not open");
      } else {
        if (r.left < -1 || r.right > vw + 1) {
          problems.push(describe(menu) + " sticks out of the viewport (" + Math.round(r.left) + " to " + Math.round(r.right) + " of " + vw + "px)");
        }
        for (const item of menu.querySelectorAll("li > a, li > button")) {
          if (item.getClientRects().length === 0) continue;
          await centre(item);
          const ir = item.getBoundingClientRect();
          const hit = document.elementFromPoint(ir.left + ir.width / 2, ir.top + ir.height / 2);
          if (!hit || !menu.contains(hit)) {
            problems.push(describe(item) + " in " + describe(menu) + " is covered or clipped by " + (hit ? describe(hit) : "nothing"));
          }
        }
      }
      if (disclosure) { disclosure.open = false; } else { trigger.blur(); }
      await sleep(150);
    }
    window.__menuProblems = problems;
  })();
  """

  setup do
    user = browser_user_fixture()
    # A long unbreakable token where a user types free text: the pet's name (100 is the cap).
    long_token = String.duplicate("unbrokenname", 8) |> String.slice(0, 100)
    pet = PetsFixtures.pet_fixture(user, %{"name" => long_token, "weight_unit" => "kilograms"})

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
        "/users/settings/two-factor",
        "/users/vet-profile"
      ]
    }
  end

  feature "signed-in pages fit the screen and their menus open fully, in both themes", %{
    session: session,
    user: user,
    paths: paths
  } do
    session = log_in_via_browser(session, user)
    assert check_layout(session, paths) == []
  end

  feature "guest pages fit the screen and their menus open fully, in both themes", %{
    session: session
  } do
    assert check_layout(session, ["/", "/users/log-in", "/users/register"]) == []
  end

  defp check_layout(session, paths) do
    for theme <- @themes,
        # The theme preference is per browser (localStorage), set once per theme.
        session = session |> visit(hd(paths)) |> execute_script(set_theme(theme)),
        {size_name, {width, height}} <- @sizes,
        session = resize_window(session, width, height),
        path <- paths,
        problem <- check_page(session, path, theme) do
      "#{theme} #{size_name} #{path} — #{problem}"
    end
  end

  defp set_theme(theme), do: "localStorage.setItem('phx:theme', '#{theme}')"

  defp check_page(session, path, theme) do
    session = visit(session, path)
    assert current_path(session) == URI.parse(path).path, "#{path} redirected"

    assert js_value(session, "return document.documentElement.getAttribute('data-theme')") ==
             theme

    js_value(session, @overflow) ++ menu_problems(session)
  end

  defp menu_problems(session) do
    execute_script(session, @menus)
    wait_for_menu_problems(session, 100)
  end

  defp wait_for_menu_problems(_session, 0), do: ["menu check did not finish"]

  defp wait_for_menu_problems(session, tries) do
    case js_value(session, "return window.__menuProblems") do
      nil -> Process.sleep(200) && wait_for_menu_problems(session, tries - 1)
      problems -> problems
    end
  end
end
