defmodule Goodmao2Web.Features.ReconnectTest do
  @moduledoc """
  The server drops a live page's socket while its session stays valid, and the page comes back.

  This is what a deploy or a restart does to every open page, and what the `"disconnect"`
  broadcast does to a session that is *not* being revoked. The client's job is to reconnect,
  rejoin the LiveView through the auth `on_mount`, and resubscribe, so an update made in the
  meantime still arrives. Nothing but a browser runs that code: the phoenix.js connection
  layer, LiveView's close handling and the reconnect-flash guard. Phoenix 1.8.16 rewrote the
  connection handling and changed the close code, so this is the gate for phoenix.js and
  LiveView client bumps alongside `session_revocation_test.exs`.
  """
  use Goodmao2Web.FeatureCase, async: false

  @moduletag :feature

  import Ecto.Query, only: [from: 2]

  alias Goodmao2.{PetsFixtures, Repo}
  alias Goodmao2.Accounts.UserToken

  # Counts socket closes seen by the page, so the test knows the drop happened before it
  # asserts the recovery (a reconnect can be faster than a poll), and marks the page so a
  # reload (LiveView's failsafe for close code 1000) is told apart from a reconnect.
  @count_drops """
  window.__samePage = true;
  window.__drops = 0;
  window.liveSocket.getSocket().onClose(() => { window.__drops += 1; });
  """

  feature "a page whose socket the server dropped reconnects and keeps receiving updates", %{
    session: session
  } do
    owner = browser_user_fixture()
    pet = PetsFixtures.pet_fixture(owner, %{"name" => "Mochi", "weight_unit" => "kilograms"})

    session =
      session
      |> log_in_via_browser(owner)
      |> visit("/pets/#{pet.id}")
      |> assert_has(Query.css("#timeline-empty"))
      |> assert_has(Query.css("[data-phx-main].phx-connected"))
      |> execute_script(@count_drops)

    # The same broadcast a revocation sends, but the session token stays: the page must
    # reconnect rather than leave.
    tokens =
      Repo.all(from t in UserToken, where: t.user_id == ^owner.id and t.context == "session")

    assert tokens != []
    Goodmao2Web.UserAuth.disconnect_sessions(tokens)

    wait_until(session, "return window.__drops > 0", "the socket was never closed")
    assert_has(session, Query.css("[data-phx-main].phx-connected"))
    assert current_path(session) == "/pets/#{pet.id}"

    # Made after the drop, so it can only arrive over a subscription the rejoined view made.
    PetsFixtures.log_entry_fixture(owner, pet, %{
      "type" => "weight",
      "data" => %{"weight_grams" => 4200}
    })

    assert_has(session, Query.css("#timeline .timeline-entry-summary", text: "4.2"))

    # A full reload would also show the entry; a reconnect keeps the page's JavaScript state.
    assert js_value(session, "return window.__samePage === true"),
           "the page was reloaded instead of reconnecting"
  end

  defp wait_until(session, script, message, tries \\ 50)
  defp wait_until(_session, _script, message, 0), do: flunk(message)

  defp wait_until(session, script, message, tries) do
    if js_value(session, script) do
      session
    else
      Process.sleep(100)
      wait_until(session, script, message, tries - 1)
    end
  end
end
