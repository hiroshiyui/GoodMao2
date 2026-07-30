defmodule Goodmao2Web.AvatarController do
  @moduledoc """
  Serves purified profile-image bytes through an authorized, IDOR-hidden endpoint (ADR-0020).

  The avatar is resolved by its **owner** id (`/avatars/user/:id`, `/avatars/pet/:id`) and the
  owner's view authorization is re-applied per request: a user avatar is visible to any
  authenticated user; a pet avatar requires `:read` on that pet. An avatar the caller can't read —
  or that isn't ready — is reported as `not_found`, exactly like one that doesn't exist. Responses
  are locked down (`nosniff`, a `default-src 'none'` sandbox CSP, `inline` disposition) and carry a
  strong `ETag` derived from the avatar's version (the same value that cache-busts the URL), so
  repeat views answer `If-None-Match` with a `304` — checked strictly *after* authorization.
  """
  use Goodmao2Web, :controller

  alias Goodmao2.Media.Avatars

  def user(conn, %{"id" => id_param}), do: serve(conn, "user", id_param)
  def pet(conn, %{"id" => id_param}), do: serve(conn, "pet", id_param)

  # sobelow_skip ["Traversal.SendFile", "Traversal.FileModule"]
  # The served path is `Storage.avatar_object_path(owner_key)` — derived solely from the row's
  # (owner_type, owner_id) after the row passed the view-authorization check. The `:id` param is
  # parsed to an integer; no request string reaches the filesystem path.
  defp serve(conn, owner_type, id_param) do
    actor = conn.assigns.current_scope.user

    with {:ok, id} <- parse_id(id_param),
         {:ok, {content_type, path, version}} <-
           Avatars.fetch_avatar_object_for_user(owner_type, id, actor),
         true <- File.exists?(path) do
      etag = ~s("v#{version}")
      conn = conn |> harden(content_type) |> put_resp_header("etag", etag)

      if none_match?(conn, etag) do
        send_resp(conn, 304, "")
      else
        send_file(conn, 200, path)
      end
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  defp parse_id(param) do
    case Integer.parse(param) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  # sobelow_skip ["XSS.ContentType"]
  # `content_type` is set by the purifier from a fixed server-side allow-list (image/jpeg,
  # image/png, image/gif, image/webp) — never from client input — and the response also carries
  # `nosniff` + a `default-src 'none'` sandbox CSP.
  defp harden(conn, content_type) do
    conn
    |> put_resp_content_type(content_type, nil)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    # These bytes skip the :browser pipeline, so nothing upstream sets this for them.
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("content-disposition", "inline")
    |> put_resp_header("cache-control", "private, no-cache")
  end

  defp none_match?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [header] ->
        header
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.any?(&(&1 == etag or &1 == "W/" <> etag or &1 == "*"))

      _ ->
        false
    end
  end
end
