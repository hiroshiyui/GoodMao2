defmodule Goodmao2Web.MessageLiveTest do
  use Goodmao2Web.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  alias Goodmao2.Messaging

  setup :register_and_log_in_user

  # Give the logged-in user a co-caretaker they share a pet with (so messaging is allowed).
  defp with_sharer(%{user: user}) do
    pet = pet_fixture(user)
    other = user_fixture()
    grant_fixture(pet, user, other, "co_caretaker")
    %{other: other, pet: pet}
  end

  describe "inbox" do
    test "shows the empty state with no conversations", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/messages")
      assert has_element?(lv, "#conversations-empty")
    end

    test "starting a conversation with a shared user navigates to the thread", %{
      conn: conn,
      user: user
    } do
      %{other: other} = with_sharer(%{user: user})

      {:ok, lv, _html} = live(conn, ~p"/messages")

      lv
      |> form("#compose-form", compose: %{identifier: other.email})
      |> render_submit()

      assert_redirect(lv, ~p"/messages/#{conversation_id(user, other)}")
    end

    test "messaging someone you share no pet with fails uniformly", %{conn: conn} do
      stranger = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/messages")

      html =
        lv
        |> form("#compose-form", compose: %{identifier: stranger.email})
        |> render_submit()

      assert html =~ "couldn&#39;t start that conversation"
    end
  end

  describe "thread" do
    test "a participant can send a message that appears", %{conn: conn, user: user} do
      %{other: other} = with_sharer(%{user: user})
      {:ok, conversation} = Messaging.start_conversation(user, other.email)

      {:ok, lv, _html} = live(conn, ~p"/messages/#{conversation.id}")

      lv
      |> form("#message-compose-form", message: %{body: "Hello there"})
      |> render_submit()

      assert has_element?(lv, ".message-body", "Hello there")
    end

    test "a non-participant is redirected (existence hidden)", %{user: user} do
      %{other: other} = with_sharer(%{user: user})
      {:ok, conversation} = Messaging.start_conversation(user, other.email)

      # A third, unrelated user tries to open the thread.
      outsider = user_fixture()
      outsider_conn = log_in_user(build_conn(), outsider)

      assert {:error, {:live_redirect, %{to: "/messages"}}} =
               live(outsider_conn, ~p"/messages/#{conversation.id}")
    end

    test "opening a thread clears its unread count", %{conn: conn, user: user} do
      %{other: other} = with_sharer(%{user: user})
      {:ok, conversation} = Messaging.start_conversation(user, other.email)
      {:ok, _} = Messaging.send_message(other, conversation, "ping")

      assert Messaging.unread_count(user) == 1
      {:ok, _lv, _html} = live(conn, ~p"/messages/#{conversation.id}")
      assert Messaging.unread_count(user) == 0
    end
  end

  defp conversation_id(a, b) do
    {:ok, conversation} = Messaging.start_conversation(a, b.email)
    conversation.id
  end
end
