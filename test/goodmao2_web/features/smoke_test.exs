defmodule Goodmao2Web.Features.SmokeTest do
  @moduledoc """
  Proves the browser harness itself works: a real page loads, and a signed-in session shares
  the test's database sandbox. If this fails, nothing else in `features/` is meaningful.
  """
  use Goodmao2Web.FeatureCase, async: false

  @moduletag :feature

  feature "serves the landing page to a guest", %{session: session} do
    session
    |> visit("/")
    |> assert_has(Query.css("#landing-title"))
  end

  feature "signs a user in and shows their pets", %{session: session} do
    user = browser_user_fixture()
    pet = pet_fixture(user, %{"name" => "Mao"})

    session
    |> log_in_via_browser(user)
    |> assert_has(Query.css("#pets-heading"))
    |> assert_has(Query.css("#pets-#{pet.id}"))
  end
end
