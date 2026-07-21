defmodule Goodmao2.MessagingTest do
  use Goodmao2.DataCase, async: true

  alias Goodmao2.Messaging
  alias Goodmao2.Messaging.Message
  alias Goodmao2.Pets

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  # Two users who share a pet (owner + co-caretaker) plus an unrelated stranger.
  defp sharing_pair do
    owner = user_fixture()
    pet = pet_fixture(owner)
    co = user_fixture()
    grant_fixture(pet, owner, co, "co_caretaker")
    %{owner: owner, co: co, pet: pet, stranger: user_fixture()}
  end

  describe "can_message?/2 (shared-pet gate)" do
    test "is true both directions when a pet is shared" do
      %{owner: owner, co: co} = sharing_pair()
      assert Messaging.can_message?(owner, co)
      assert Messaging.can_message?(co, owner)
    end

    test "is false for two users who share no pet" do
      %{owner: owner, stranger: stranger} = sharing_pair()
      refute Messaging.can_message?(owner, stranger)
    end

    test "is false once the shared grant has expired" do
      %{owner: owner, co: co, pet: pet} = sharing_pair()

      Pets.effective_access(pet, co)

      Repo.update_all(Pets.PetAccess,
        set: [
          expires_at: DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
        ]
      )

      refute Messaging.can_message?(owner, co)
    end

    test "is false for a user with themselves" do
      %{owner: owner} = sharing_pair()
      refute Messaging.can_message?(owner, owner)
    end
  end

  describe "start_conversation/2 (uniform non-leaking error)" do
    test "starts a conversation between users who share a pet" do
      %{owner: owner, co: co} = sharing_pair()
      assert {:ok, conversation} = Messaging.start_conversation(owner, co.email)
      assert conversation.id
    end

    test "returns the SAME conversation regardless of initiator (idempotent + canonical)" do
      %{owner: owner, co: co} = sharing_pair()
      assert {:ok, c1} = Messaging.start_conversation(owner, co.email)
      assert {:ok, c2} = Messaging.start_conversation(co, owner.email)
      assert c1.id == c2.id
    end

    test "no shared pet and unknown recipient give the IDENTICAL error" do
      %{owner: owner, stranger: stranger} = sharing_pair()

      no_pet = Messaging.start_conversation(owner, stranger.email)
      unknown = Messaging.start_conversation(owner, "nobody@nowhere.test")
      itself = Messaging.start_conversation(owner, owner.email)

      assert no_pet == {:error, :cannot_message}
      assert unknown == {:error, :cannot_message}
      assert itself == {:error, :cannot_message}
    end
  end

  describe "messages + participant guard (existence-hidden)" do
    test "a participant can send and list messages" do
      %{owner: owner, co: co} = sharing_pair()
      {:ok, conversation} = Messaging.start_conversation(owner, co.email)

      assert {:ok, %Message{} = message} =
               Messaging.send_message(owner, conversation, "How is Mittens today?")

      assert message.body == "How is Mittens today?"

      assert ["How is Mittens today?"] =
               Enum.map(Messaging.list_messages(co, conversation), & &1.body)
    end

    test "a non-participant is hidden from every thread read/write" do
      %{owner: owner, co: co, stranger: stranger} = sharing_pair()
      {:ok, conversation} = Messaging.start_conversation(owner, co.email)

      assert Messaging.fetch_conversation(stranger, conversation.id) == nil
      assert Messaging.list_messages(stranger, conversation) == nil
      assert Messaging.send_message(stranger, conversation, "hi") == {:error, :not_participant}
    end

    test "a blank message is rejected" do
      %{owner: owner, co: co} = sharing_pair()
      {:ok, conversation} = Messaging.start_conversation(owner, co.email)
      assert {:error, changeset} = Messaging.send_message(owner, conversation, "   ")
      assert %{body: _} = errors_on(changeset)
    end

    test "a message over 2000 codepoints is rejected" do
      %{owner: owner, co: co} = sharing_pair()
      {:ok, conversation} = Messaging.start_conversation(owner, co.email)
      too_long = String.duplicate("x", 2001)
      assert {:error, changeset} = Messaging.send_message(owner, conversation, too_long)
      assert %{body: _} = errors_on(changeset)
    end
  end

  describe "unread counts + read cursor" do
    test "a message is unread for the recipient, not the sender" do
      %{owner: owner, co: co} = sharing_pair()
      {:ok, conversation} = Messaging.start_conversation(owner, co.email)
      {:ok, _} = Messaging.send_message(owner, conversation, "ping")

      assert Messaging.unread_count(co) == 1
      assert Messaging.unread_count(owner) == 0
    end

    test "mark_conversation_read advances the cursor to zero unread" do
      %{owner: owner, co: co} = sharing_pair()
      {:ok, conversation} = Messaging.start_conversation(owner, co.email)
      {:ok, _} = Messaging.send_message(owner, conversation, "ping")

      assert {:ok, _} = Messaging.mark_conversation_read(co, conversation)
      assert Messaging.unread_count(co) == 0
    end

    test "list_conversations reports the other user and the per-thread unread count" do
      %{owner: owner, co: co} = sharing_pair()
      {:ok, conversation} = Messaging.start_conversation(owner, co.email)
      {:ok, _} = Messaging.send_message(owner, conversation, "ping")

      assert [entry] = Messaging.list_conversations(co)
      assert entry.conversation.id == conversation.id
      assert entry.other_user.id == owner.id
      assert entry.unread == 1
    end
  end
end
