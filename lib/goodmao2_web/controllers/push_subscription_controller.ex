defmodule Goodmao2Web.PushSubscriptionController do
  @moduledoc """
  JSON endpoints for a user to register/unregister their browser Web Push subscription
  (ADR-0011 Stage 2).

  Served through the `:browser` pipeline (not `:api`) so it inherits session auth **and**
  CSRF protection — the client sends the `x-csrf-token` header. The `p256dh`/`auth` keys are
  base64url-decoded and their exact byte sizes checked before anything is stored, and each
  write is per-user rate-limited. The endpoint itself is SSRF-validated in the changeset.
  """
  use Goodmao2Web, :controller

  alias Goodmao2.Notifications
  alias Goodmao2.Notifications.PushRateLimiter

  @doc "Registers or refreshes the current user's subscription for a push endpoint."
  def create(conn, params) do
    user = conn.assigns.current_scope.user

    with :ok <- PushRateLimiter.check(user.id),
         {:ok, p256dh} <- decode_base64url(params["p256dh"], "p256dh"),
         :ok <- validate_size(p256dh, 65, "p256dh"),
         {:ok, auth} <- decode_base64url(params["auth"], "auth"),
         :ok <- validate_size(auth, 16, "auth") do
      attrs = %{
        endpoint: params["endpoint"],
        p256dh: p256dh,
        auth: auth,
        user_agent: params["user_agent"]
      }

      case Notifications.upsert_push_subscription(user, attrs) do
        {:ok, _subscription} ->
          json(conn, %{status: "ok"})

        {:error, :endpoint_conflict} ->
          conn |> put_status(:conflict) |> json(%{error: "endpoint_conflict"})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: changeset_errors(changeset)})
      end
    else
      {:error, :rate_limited} ->
        conn |> put_status(:too_many_requests) |> json(%{error: "rate_limited"})

      {:error, field} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{field => ["invalid base64url encoding"]}})

      {:error, field, :invalid_size} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{field => ["invalid size"]}})
    end
  end

  @doc "Unsubscribes the current user from a push endpoint (soft-delete)."
  def delete(conn, params) do
    user = conn.assigns.current_scope.user

    case Notifications.delete_push_subscription(user, params["endpoint"] || "") do
      {:ok, _subscription} ->
        json(conn, %{status: "ok"})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "not_found"})
    end
  end

  # --- private ---

  defp decode_base64url(value, field) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, field}
    end
  end

  defp decode_base64url(_, field), do: {:error, field}

  defp validate_size(binary, expected, _field) when byte_size(binary) == expected, do: :ok
  defp validate_size(_binary, _expected, field), do: {:error, field, :invalid_size}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
