defmodule Goodmao2Web.PushSubscriptionControllerTest do
  use Goodmao2Web.ConnCase, async: true

  import Goodmao2.AccountsFixtures

  alias Goodmao2.Notifications.PushSubscription
  alias Goodmao2.Repo

  setup :register_and_log_in_user

  defp keys do
    {p256dh, _} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "endpoint" => "https://push.example.com/#{System.unique_integer([:positive])}",
      "p256dh" => Base.url_encode64(p256dh, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false),
      "user_agent" => "Test/1.0"
    }
  end

  describe "create" do
    test "registers a subscription for the current user", %{conn: conn, user: user} do
      params = keys()
      conn = post(conn, ~p"/api/push-subscriptions", params)

      assert json_response(conn, 200) == %{"status" => "ok"}
      sub = Repo.get_by(PushSubscription, endpoint: params["endpoint"])
      assert sub.user_id == user.id
      assert byte_size(sub.p256dh) == 65
    end

    test "upserts (refreshes) an existing endpoint for the same user", %{conn: conn} do
      params = keys()
      post(conn, ~p"/api/push-subscriptions", params)
      conn = post(conn, ~p"/api/push-subscriptions", params)

      assert json_response(conn, 200) == %{"status" => "ok"}
      assert Repo.aggregate(PushSubscription, :count) == 1
    end

    test "409 when the endpoint belongs to another user", %{conn: conn} do
      params = keys()
      post(conn, ~p"/api/push-subscriptions", params)

      other_conn = log_in_user(build_conn(), user_fixture())
      other_conn = post(other_conn, ~p"/api/push-subscriptions", params)

      assert json_response(other_conn, 409) == %{"error" => "endpoint_conflict"}
    end

    test "422 on a wrong-size p256dh", %{conn: conn} do
      params = %{keys() | "p256dh" => Base.url_encode64("short", padding: false)}
      conn = post(conn, ~p"/api/push-subscriptions", params)
      assert %{"errors" => %{"p256dh" => ["invalid size"]}} = json_response(conn, 422)
    end

    test "422 on non-base64url keys", %{conn: conn} do
      params = %{keys() | "auth" => "!!!not base64!!!"}
      conn = post(conn, ~p"/api/push-subscriptions", params)
      assert %{"errors" => %{"auth" => ["invalid base64url encoding"]}} = json_response(conn, 422)
    end

    test "redirects an unauthenticated caller to log in", %{} do
      conn = post(build_conn(), ~p"/api/push-subscriptions", keys())
      assert redirected_to(conn) =~ "/users/log-in"
    end
  end

  describe "delete" do
    test "soft-deletes the current user's subscription", %{conn: conn} do
      params = keys()
      post(conn, ~p"/api/push-subscriptions", params)

      conn = delete(conn, ~p"/api/push-subscriptions", %{"endpoint" => params["endpoint"]})
      assert json_response(conn, 200) == %{"status" => "ok"}
      assert Repo.get_by(PushSubscription, endpoint: params["endpoint"]).deleted_at
    end

    test "404 for an unknown endpoint", %{conn: conn} do
      conn =
        delete(conn, ~p"/api/push-subscriptions", %{"endpoint" => "https://push.example.com/nope"})

      assert json_response(conn, 404) == %{"error" => "not_found"}
    end
  end
end
