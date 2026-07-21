defmodule Goodmao2.Messaging.MessagePushWorkerTest do
  use Goodmao2.DataCase, async: true
  use Oban.Testing, repo: Goodmao2.Repo

  import Goodmao2.AccountsFixtures
  import Goodmao2.PetsFixtures

  alias Goodmao2.Messaging
  alias Goodmao2.Messaging.MessagePushWorker
  alias Goodmao2.Notifications.PushSubscription
  alias Goodmao2.Notifications.WebPush
  alias Goodmao2.Notifications.WebPush.SafeClient
  alias Goodmao2.Settings

  # owner and co share a pet, so they can message each other.
  defp pair do
    owner = user_fixture()
    pet = pet_fixture(owner)
    co = user_fixture()
    grant_fixture(pet, owner, co, "co_caretaker")
    {:ok, conversation} = Messaging.start_conversation(owner, co.email)
    %{owner: owner, co: co, conversation: conversation}
  end

  defp configure_vapid do
    {public_key, encrypted_private} = WebPush.generate_keypair()
    {:ok, _} = Settings.put("vapid_public_key", public_key)
    {:ok, _} = Settings.put("vapid_private_key_encrypted", Base.encode64(encrypted_private))
  end

  defp subscribe(user) do
    {p256dh, _} = :crypto.generate_key(:ecdh, :prime256v1)

    {:ok, sub} =
      %PushSubscription{}
      |> PushSubscription.changeset(%{
        endpoint: "https://push.example.com/#{System.unique_integer([:positive])}",
        p256dh: p256dh,
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      })
      |> Repo.insert()

    sub
  end

  describe "send_message enqueue gating" do
    test "does NOT enqueue a push when VAPID is unconfigured" do
      %{owner: owner, conversation: conversation} = pair()
      {:ok, _} = Messaging.send_message(owner, conversation, "hi")
      refute_enqueued(worker: MessagePushWorker)
    end

    test "enqueues a message push when VAPID is configured" do
      configure_vapid()
      %{owner: owner, conversation: conversation} = pair()
      {:ok, message} = Messaging.send_message(owner, conversation, "hi")
      assert_enqueued(worker: MessagePushWorker, args: %{"message_id" => message.id})
    end
  end

  describe "perform/1" do
    setup do
      configure_vapid()
      :ok
    end

    test "pushes to the recipient's subscriptions, never the sender's" do
      %{owner: owner, co: co, conversation: conversation} = pair()
      _sender_sub = subscribe(owner)
      _recipient_sub = subscribe(co)
      {:ok, message} = Messaging.send_message(owner, conversation, "How is Mittens?")

      test_pid = self()

      Req.Test.stub(SafeClient, fn conn ->
        send(test_pid, :push_sent)
        Plug.Conn.send_resp(conn, 201, "")
      end)

      assert :ok = perform_job(MessagePushWorker, %{"message_id" => message.id})

      # Exactly one push — to the recipient (co), not the sender (owner).
      assert_received :push_sent
      refute_received :push_sent
    end
  end
end
