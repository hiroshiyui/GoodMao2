defmodule Goodmao2.Media.Purifier do
  @moduledoc """
  Actively purifies an uploaded file into clean, metadata-free bytes (ADR-0005).

  The overriding requirement is that **every byte is purified, not merely validated**:

    * **Content type comes from magic bytes**, never the client header or filename. Anything
      not on the allow-list — including SVG (active-content XML) — is rejected.
    * **Images** are decoded and **re-encoded** with `ffmpeg -map_metadata -1`, which strips
      all EXIF/GPS/IPTC/XMP and, because the stored bytes are the encoder's fresh output, also
      neutralizes polyglots and trailing payloads. The re-encode also **flattens away any alpha
      channel** onto an opaque background, so a transparent image can't hide deceptive content.
    * **Byte-size caps and min/max pixel dimensions** are enforced against the
      admin-configurable `Goodmao2.Media.Limits` (per-kind, images and videos alike).
    * **Videos** are probed (codec allow-list + duration cap) then **remuxed** with
      `-map_metadata -1` and only the first video/audio stream mapped — dropping container GPS,
      chapters, and any data/subtitle streams.

  On success returns `{:ok, %{kind, content_type, path, byte_size}}` where `path` is a fresh
  temp file the caller must move into storage and then clean up.
  """
  require Logger

  alias Goodmao2.Media.Limits

  # Magic-byte signatures → the format we accept. SVG and everything else fall through to
  # `{:error, :unsupported_type}`. Videos are container-probed further below.
  @image_types %{
    jpeg: %{content_type: "image/jpeg", ext: "jpg"},
    png: %{content_type: "image/png", ext: "png"},
    gif: %{content_type: "image/gif", ext: "gif"},
    webp: %{content_type: "image/webp", ext: "webp"}
  }

  @video_types %{
    mp4: %{content_type: "video/mp4", ext: "mp4", video: ~w(h264), audio: ~w(aac)},
    webm: %{
      content_type: "video/webm",
      ext: "webm",
      video: ~w(vp8 vp9 av1),
      audio: ~w(opus vorbis)
    }
  }

  @doc "Purifies `source_path`. See the module doc for the guarantees."
  def purify(source_path) do
    with {:ok, format} <- detect(source_path),
         {:ok, _size} <- within_size?(source_path, format) do
      process(format, source_path)
    end
  end

  # --- Magic-byte detection --------------------------------------------------

  defp detect(path) do
    case read_head(path) do
      <<0xFF, 0xD8, 0xFF, _::binary>> -> {:ok, {:image, :jpeg}}
      <<0x89, "PNG\r\n", 0x1A, 0x0A, _::binary>> -> {:ok, {:image, :png}}
      <<"GIF87a", _::binary>> -> {:ok, {:image, :gif}}
      <<"GIF89a", _::binary>> -> {:ok, {:image, :gif}}
      <<"RIFF", _::binary-size(4), "WEBP", _::binary>> -> {:ok, {:image, :webp}}
      <<0x1A, 0x45, 0xDF, 0xA3, _::binary>> -> {:ok, {:video, :webm}}
      <<_::binary-size(4), "ftyp", _::binary>> -> {:ok, {:video, :mp4}}
      _ -> {:error, :unsupported_type}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # `path` is an upload temp file from LiveView / a caller-owned path, opened read-only to
  # sniff magic bytes — no path is constructed from user-controlled strings.
  defp read_head(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        head = IO.binread(io, 32)
        File.close(io)
        if is_binary(head), do: head, else: ""

      _ ->
        ""
    end
  end

  defp within_size?(path, {kind, _}) do
    limit =
      case kind do
        :image -> Limits.get(:max_image_bytes)
        :video -> Limits.get(:max_video_bytes)
      end

    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 and size <= limit -> {:ok, size}
      {:ok, %{size: size}} when size > limit -> {:error, :too_large}
      _ -> {:error, :unreadable}
    end
  end

  # --- Processing ------------------------------------------------------------

  defp process({:image, format}, source) do
    %{content_type: content_type, ext: ext} = @image_types[format]

    with {:ok, %{"streams" => streams}} <- probe(source),
         {:ok, {w, h}} <- dimensions(streams),
         :ok <- within_resolution?(w, h, :image) do
      out = temp_path(ext)

      # Re-encode pixels, flatten any alpha onto opaque white, and strip every metadata block.
      # `flatten_alpha/0` composites the frame over an opaque box then drops the alpha plane, so
      # a transparent region cannot smuggle hidden pixels. Per-frame, so gif/webp animation survives.
      args = [
        "-y",
        "-nostdin",
        "-v",
        "error",
        "-i",
        source,
        "-filter_complex",
        flatten_alpha(),
        "-map",
        "[out]",
        "-map_metadata",
        "-1",
        out
      ]

      with :ok <- run("ffmpeg", args),
           {:ok, size} <- output_size(out) do
        {:ok, %{kind: "image", content_type: content_type, path: out, byte_size: size}}
      else
        error -> cleanup_and(out, error)
      end
    end
  end

  defp process({:video, format}, source) do
    spec = @video_types[format]
    out = temp_path(spec.ext)

    with {:ok, %{"streams" => streams, "format" => fmt}} <- probe(source),
         :ok <- validate_video(streams, fmt, spec),
         :ok <- remux(source, out, format),
         {:ok, size} <- output_size(out) do
      {:ok, %{kind: "video", content_type: spec.content_type, path: out, byte_size: size}}
    else
      {:error, _} = error -> cleanup_and(out, error)
    end
  end

  # Duplicate the frame, paint one copy fully opaque white, overlay the original (honouring its
  # alpha) on top, then force an alpha-less pixel format. Needs no knowledge of the dimensions.
  defp flatten_alpha do
    "split[fg][bg];" <>
      "[bg]drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill[bgf];" <>
      "[bgf][fg]overlay=format=auto,format=rgb24[out]"
  end

  defp validate_video(streams, fmt, spec) do
    duration = fmt |> Map.get("duration", "0") |> to_float()
    video = Enum.find(streams, &(&1["codec_type"] == "video"))
    audios = Enum.filter(streams, &(&1["codec_type"] == "audio"))

    cond do
      duration <= 0 or duration > config(:max_video_seconds) ->
        {:error, :bad_duration}

      is_nil(video) ->
        {:error, :no_video_stream}

      video["codec_name"] not in spec.video ->
        {:error, :disallowed_video_codec}

      Enum.any?(audios, &(&1["codec_name"] not in spec.audio)) ->
        {:error, :disallowed_audio_codec}

      true ->
        with {:ok, {w, h}} <- dimensions([video]), do: within_resolution?(w, h, :video)
    end
  end

  # --- Resolution -----------------------------------------------------------

  # The width/height of the first video stream (ffprobe reports a still image as one such stream).
  defp dimensions(streams) do
    case Enum.find(streams, &(&1["codec_type"] == "video")) do
      %{"width" => w, "height" => h} when is_integer(w) and is_integer(h) and w > 0 and h > 0 ->
        {:ok, {w, h}}

      _ ->
        {:error, :bad_dimensions}
    end
  end

  # Enforce the admin-configurable floor/ceiling (`0` on either side = unbounded).
  defp within_resolution?(w, h, kind) do
    %{min_w: min_w, min_h: min_h, max_w: max_w, max_h: max_h} = resolution_bounds(kind)

    cond do
      w < min_w or h < min_h -> {:error, :below_min_resolution}
      max_w > 0 and w > max_w -> {:error, :above_max_resolution}
      max_h > 0 and h > max_h -> {:error, :above_max_resolution}
      true -> :ok
    end
  end

  defp resolution_bounds(:image) do
    %{
      min_w: Limits.get(:min_image_width),
      min_h: Limits.get(:min_image_height),
      max_w: Limits.get(:max_image_width),
      max_h: Limits.get(:max_image_height)
    }
  end

  defp resolution_bounds(:video) do
    %{
      min_w: Limits.get(:min_video_width),
      min_h: Limits.get(:min_video_height),
      max_w: Limits.get(:max_video_width),
      max_h: Limits.get(:max_video_height)
    }
  end

  # Copy the first video + optional first audio stream, strip all metadata/chapters and any
  # data/subtitle streams. No re-encode (fast), but the container is rebuilt clean.
  defp remux(source, out, :mp4) do
    run("ffmpeg", [
      "-y",
      "-nostdin",
      "-v",
      "error",
      "-i",
      source,
      "-map",
      "0:v:0",
      "-map",
      "0:a:0?",
      "-c",
      "copy",
      "-map_metadata",
      "-1",
      "-map_chapters",
      "-1",
      "-movflags",
      "+faststart",
      "-f",
      "mp4",
      out
    ])
  end

  defp remux(source, out, :webm) do
    run("ffmpeg", [
      "-y",
      "-nostdin",
      "-v",
      "error",
      "-i",
      source,
      "-map",
      "0:v:0",
      "-map",
      "0:a:0?",
      "-c",
      "copy",
      "-map_metadata",
      "-1",
      "-map_chapters",
      "-1",
      "-f",
      "webm",
      out
    ])
  end

  # sobelow_skip ["CI.System"]
  # Fixed executable + argument list (no shell); `source` is a file path passed as an argv
  # element, so no command string is interpolated.
  defp probe(source) do
    args = [
      "-v",
      "error",
      "-print_format",
      "json",
      "-show_format",
      "-show_streams",
      source
    ]

    case System.cmd("ffprobe", args, stderr_to_stdout: true) do
      {out, 0} -> Jason.decode(out)
      _ -> {:error, :probe_failed}
    end
  end

  # --- ffmpeg/ffprobe invocation --------------------------------------------

  # sobelow_skip ["CI.System"]
  # Fixed executable + argument list (no shell); args are literals plus caller-owned file
  # paths passed as argv elements — nothing is interpolated into a command string.
  defp run(cmd, args) do
    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Logger.warning("#{cmd} exited #{code}: #{String.slice(out, 0, 500)}")
        {:error, :processing_failed}
    end
  end

  defp output_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> {:ok, size}
      _ -> {:error, :empty_output}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  # `path` is our own generated temp output path — never user input.
  defp cleanup_and(path, error) do
    _ = File.rm(path)
    error
  end

  defp temp_path(ext) do
    name = "gm_media_#{System.unique_integer([:positive])}.#{ext}"
    Path.join(System.tmp_dir!(), name)
  end

  defp to_float(bin) when is_binary(bin) do
    case Float.parse(bin) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp to_float(_), do: 0.0

  defp config(key), do: Application.fetch_env!(:goodmao2, Goodmao2.Media)[key]
end
