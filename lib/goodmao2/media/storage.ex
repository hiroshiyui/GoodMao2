defmodule Goodmao2.Media.Storage do
  @moduledoc """
  The storage seam for purified media objects (ADR-0005).

  A local-filesystem store whose object path is **derived solely from the integer asset id**
  (sharded to keep directories small) and never persisted — so it is path-traversal-proof by
  construction. Swapping in an S3-compatible backend later means reimplementing this module
  behind the same functions; nothing else changes.
  """

  @doc "The configured storage root — a writable directory outside any served path."
  def storage_dir do
    Application.fetch_env!(:goodmao2, Goodmao2.Media)[:storage_dir] ||
      raise "media storage_dir is not configured (see config and ADR-0005)"
  end

  @doc "The object path for an asset id. Derived from the id alone — never taken from input."
  def object_path(id) when is_integer(id) do
    shard = id |> rem(256) |> Integer.to_string() |> String.pad_leading(3, "0")
    Path.join([storage_dir(), shard, Integer.to_string(id)])
  end

  @doc "Copies the purified `source_path` into storage under `id`."
  # sobelow_skip ["Traversal.FileModule"]
  # The destination is derived solely from the integer id (never from input); the source is a
  # temp file we purified. No user-controlled path reaches File.mkdir_p/File.copy.
  def store(id, source_path) when is_integer(id) do
    dest = object_path(id)

    with :ok <- File.mkdir_p(Path.dirname(dest)),
         {:ok, _bytes} <- File.copy(source_path, dest) do
      :ok
    end
  end

  @doc "Removes an asset's bytes (best-effort; a missing object is not an error)."
  # sobelow_skip ["Traversal.FileModule"]
  # Path derived from the integer id alone — never from input.
  def delete(id) when is_integer(id) do
    _ = File.rm(object_path(id))
    :ok
  end

  @doc "Whether an asset's bytes are present."
  def exists?(id) when is_integer(id), do: File.exists?(object_path(id))
end
