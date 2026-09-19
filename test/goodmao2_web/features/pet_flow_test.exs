defmodule Goodmao2Web.Features.PetFlowTest do
  @moduledoc """
  The product's spine in a real browser: sign in, add a pet, log something, see it.

  The LiveView tests cover each of these steps against the LiveView process. What they cannot
  cover is the part that only exists in a browser -- that the QuickLog panel is a `<details>`
  whose open state survives a patch, that clicking a type chip re-renders the right fields,
  and that an entry logged in one session reaches another caretaker's already-open page over
  PubSub rather than on their next refresh.
  """
  use Goodmao2Web.FeatureCase, async: false

  @moduletag :feature

  alias Goodmao2.PetsFixtures

  feature "signs in, adds a pet, and lands on its timeline", %{session: session} do
    user = browser_user_fixture()

    session
    |> log_in_via_browser(user)
    |> click(Query.css("#new-pet-button"))
    |> fill_in(Query.css("#pet-form input[name='pet[name]']"), with: "Mochi")
    |> click(Query.css("#pet-form-submit"))
    # Landing on the pet page is the redirect working; the name is the record having been
    # written through the form rather than a fixture.
    |> assert_has(Query.css("#pet-name", text: "Mochi"))
    |> assert_has(Query.css("#timeline-section"))
  end

  feature "logs a weight through QuickLog and shows it on the timeline", %{session: session} do
    user = browser_user_fixture()
    pet = PetsFixtures.pet_fixture(user, %{"name" => "Mochi", "weight_unit" => "kilograms"})

    session
    |> log_in_via_browser(user)
    |> visit("/pets/#{pet.id}")
    |> assert_has(Query.css("#quicklog-section"))
    |> click(Query.css("#quicklog-type-weight"))
    # The chip reports its own state, so this is also the check that selecting a type is
    # announced rather than only coloured.
    |> assert_has(Query.css("#quicklog-type-weight[aria-pressed='true']"))
    |> fill_in(Query.css("#quicklog-form input[type=number]"), with: "4.2")
    |> click(Query.css("#quicklog-submit"))
    |> assert_has(Query.css("#timeline .timeline-entry-summary", text: "4.2"))
  end

  feature "streams a co-caretaker's entry into an already-open timeline", %{session: session} do
    owner = browser_user_fixture()
    helper = browser_user_fixture()
    pet = PetsFixtures.pet_fixture(owner, %{"name" => "Mochi", "weight_unit" => "kilograms"})
    PetsFixtures.grant_fixture(pet, owner, helper, "co_caretaker")

    # The helper is watching the pet's page and never reloads it.
    watcher = start_another_session()

    watcher
    |> log_in_via_browser(helper)
    |> visit("/pets/#{pet.id}")
    |> assert_has(Query.css("#timeline-empty"))

    session
    |> log_in_via_browser(owner)
    |> visit("/pets/#{pet.id}")
    |> click(Query.css("#quicklog-type-weight"))
    |> fill_in(Query.css("#quicklog-form input[type=number]"), with: "4.2")
    |> click(Query.css("#quicklog-submit"))
    |> assert_has(Query.css("#timeline .timeline-entry-summary"))

    # Nothing touched this session; the entry has to arrive over the pet's PubSub topic.
    assert_has(watcher, Query.css("#timeline .timeline-entry-summary", text: "4.2"))
  end
end
