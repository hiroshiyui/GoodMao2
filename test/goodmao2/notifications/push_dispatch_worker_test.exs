defmodule Goodmao2.Notifications.PushDispatchWorkerTest do
  use Goodmao2.DataCase, async: true
  use Oban.Testing, repo: Goodmao2.Repo

  import Goodmao2.AccountsFixtures

  alias Goodmao2.Notifications
  alias Goodmao2.Notifications.PushDispatchWorker
  alias Goodmao2.Notifications.PushSubscription
  alias Goodmao2.Notifications.WebPush
  alias Goodmao2.Notifications.WebPush.SafeClient
  alias Goodmao2.Settings

  defp configure_vapid do
    {public_key, encrypted_private} = WebPush.generate_keypair()
    {:ok, _} = Settings.put("vapid_public_key", public_key)
    {:ok, _} = Settings.put("vapid_private_key_encrypted", Base.encode64(encrypted_private))
  end

  defp insert_subscription(user, opts \\ []) do
    {p256dh, _} = :crypto.generate_key(:ecdh, :prime256v1)

    {:ok, subscription} =
      %PushSubscription{}
      |> PushSubscription.changeset(%{
        endpoint: "https://push.example.com/#{System.unique_integer([:positive])}",
        p256dh: p256dh,
        auth: :crypto.strong_rand_bytes(16),
        user_id: user.id
      })
      |> Repo.insert()

    case opts[:deleted_at] do
      nil -> subscription
      at -> subscription |> Ecto.Changeset.change(deleted_at: at) |> Repo.update!()
    end
  end

  defp announce(user),
    do: Notifications.create(user.id, "announcement", %{"title" => "t", "body" => "b"})

  describe "create/3 enqueue gating" do
    test "does NOT enqueue a push when VAPID is unconfigured" do
      user = user_fixture()
      {:ok, _} = announce(user)
      refute_enqueued(worker: PushDispatchWorker)
    end

    test "enqueues a push dispatch when VAPID is configured" do
      configure_vapid()
      user = user_fixture()
      {:ok, notification} = announce(user)
      assert_enqueued(worker: PushDispatchWorker, args: %{"notification_id" => notification.id})
    end
  end

  describe "perform/1" do
    setup do
      configure_vapid()
      :ok
    end

    test "sends one push per live subscription and skips soft-deleted ones" do
      test_pid = self()

      Req.Test.stub(SafeClient, fn conn ->
        send(test_pid, :push_sent)
        Plug.Conn.send_resp(conn, 201, "")
      end)

      user = user_fixture()
      _live = insert_subscription(user)
      _stale = insert_subscription(user, deleted_at: ~U[2020-01-01 00:00:00Z])
      {:ok, notification} = announce(user)

      assert :ok = perform_job(PushDispatchWorker, %{"notification_id" => notification.id})

      assert_received :push_sent
      refute_received :push_sent
    end

    test "is a no-op when the user has no subscriptions" do
      user = user_fixture()
      {:ok, notification} = announce(user)
      assert :ok = perform_job(PushDispatchWorker, %{"notification_id" => notification.id})
    end
  end
end
