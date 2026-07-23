defmodule Goodmao2Web.MediaController do
  @moduledoc """
  Serves purified life-log media bytes through an authorized, IDOR-hidden endpoint (ADR-0005).

  There is **no `pet_id` in the URL to forge** — the asset is resolved by its own id and the
  parent log's read authorization (grant + ADR-0004 visibility + recorder + hidden-history) is
  re-applied per request. An asset the caller can't read is reported as `not_found`, exactly
  like one that doesn't exist. Responses are locked down (`nosniff`, a `default-src 'none'`
  sandbox CSP, `inline` disposition) and support `Range` for video seeking.
  """
  use Goodmao2Web, :controller

  alias Goodmao2.{Logs, Media}
  alias Goodmao2.Media.Storage

  # sobelow_skip ["Traversal.SendFile", "Traversal.FileModule"]
  # The served path is `Storage.object_path(asset.id)` — derived solely from the DB row's
  # integer id after the row passed the full read-authorization check. No request string
  # (the `:id` param is parsed to an integer) reaches the filesystem path.
  def show(conn, %{"id" => id_param}) do
    user = conn.assigns.current_scope.user

    with {:ok, id} <- parse_id(id_param),
         {:ok, asset} <- Media.fetch_asset_for_user(user, id),
         path = Storage.object_path(asset.id),
         true <- File.exists?(path) do
      conn |> harden(asset) |> send_bytes(path, asset.byte_size)
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end

  # sobelow_skip ["Traversal.SendFile", "Traversal.FileModule"]
  # Anonymous byte serving for a `public` entry's media (ADR-0004). Authorization is the parent
  # entry's still-live share token — re-resolved per request — and the asset must belong to that
  # entry; only then is `Storage.object_path(asset.id)` (an id-derived path, never a request
  # string) touched. A dead token or an unrelated media id is existence-hidden, like `show/2`.
  def shared(conn, %{"token" => token, "id" => id_param}) do
    with {:ok, id} <- parse_id(id_param),
         %{media_assets: assets} <- Logs.fetch_entry_by_share_token(token),
         %Media.MediaAsset{} = asset <- Enum.find(assets, &(&1.id == id)),
         path = Storage.object_path(asset.id),
         true <- File.exists?(path) do
      conn |> harden(asset) |> send_bytes(path, asset.byte_size)
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
  # image/png, image/gif, image/webp, video/mp4, video/webm) — never from client input — and
  # the response also carries `nosniff` + a `default-src 'none'` sandbox CSP.
  defp harden(conn, asset) do
    conn
    |> put_resp_content_type(asset.content_type, nil)
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
    # These bytes skip the :browser pipeline, so nothing upstream sets this for them.
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("content-disposition", "inline")
    |> put_resp_header("cache-control", "private, no-cache")
    |> put_resp_header("accept-ranges", "bytes")
  end

  # Single-range support (enough for video seeking); anything malformed is a 416.
  # sobelow_skip ["Traversal.SendFile"]
  # `path` is the id-derived storage path from `show/2` (see its note) — not user input.
  defp send_bytes(conn, path, size) do
    case get_req_header(conn, "range") do
      ["bytes=" <> spec] ->
        case parse_range(spec, size) do
          {:ok, first, last} ->
            conn
            |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
            |> send_file(206, path, first, last - first + 1)

          :error ->
            conn
            |> put_resp_header("content-range", "bytes */#{size}")
            |> send_resp(416, "")
        end

      _ ->
        send_file(conn, 200, path, 0, size)
    end
  end

  defp parse_range(spec, size) do
    case String.split(spec, "-", parts: 2) do
      # bytes=N-  → N to end
      [start, ""] ->
        with {first, ""} <- Integer.parse(start), true <- first >= 0 and first < size do
          {:ok, first, size - 1}
        else
          _ -> :error
        end

      # bytes=-N  → last N bytes
      ["", suffix] ->
        with {n, ""} <- Integer.parse(suffix), true <- n > 0 do
          {:ok, max(size - n, 0), size - 1}
        else
          _ -> :error
        end

      # bytes=A-B
      [start, stop] ->
        with {first, ""} <- Integer.parse(start),
             {last, ""} <- Integer.parse(stop),
             true <- first <= last and first < size do
          {:ok, first, min(last, size - 1)}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end
end
