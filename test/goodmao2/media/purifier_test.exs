defmodule Goodmao2.Media.PurifierTest do
  # async: false — shells out to ffmpeg/ffprobe and reads Limits from the DB.
  use Goodmao2.DataCase, async: false

  alias Goodmao2.Media.Purifier

  # A multi-frame source whose magic bytes read as a plain still image — the shape of a real
  # APNG upload or a phone multi-picture/motion JPEG. ffmpeg's single-image muxer aborts on the
  # second frame unless the purifier pins the output to the primary frame.
  defp make_apng do
    path = Path.join(System.tmp_dir!(), "gm_purify_#{System.unique_integer([:positive])}.png")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -v error -f lavfi -i testsrc=s=800x600:d=1:r=2 -f apng -y) ++ [path]
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp count_frames(path) do
    {out, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -count_frames -select_streams v:0
           -show_entries stream=nb_read_frames -of csv=p=0) ++ [path]
      )

    out |> String.trim() |> String.to_integer()
  end

  test "a multi-frame still image (APNG) purifies to its primary frame instead of failing" do
    src = make_apng()

    assert {:ok, purified} = Purifier.purify(src)
    on_exit(fn -> File.rm(purified.path) end)

    assert purified.kind == "image"
    assert purified.content_type == "image/png"
    assert count_frames(purified.path) == 1
  end

  describe "audit 2026-11-15" do
    # A WebM whose Segment Duration claims `declared_ms` while its clusters carry 3 s.
    defp make_lying_webm(declared_ms) do
      path = Path.join(System.tmp_dir!(), "gm_lie_#{System.unique_integer([:positive])}.webm")

      {_, 0} =
        System.cmd(
          "ffmpeg",
          ~w(-hide_banner -v error -f lavfi -i testsrc=s=640x480:d=3:r=10
             -c:v libvpx-vp9 -cues_to_front 0 -y) ++ [path]
        )

      bytes = File.read!(path)
      [{at, _}] = :binary.matches(bytes, <<0x44, 0x89, 0x88>>)
      head_size = at + 3
      <<head::binary-size(^head_size), _old::float-64, rest::binary>> = bytes
      File.write!(path, [head, <<declared_ms * 1.0::float-64>>, rest])
      on_exit(fn -> File.rm(path) end)
      path
    end

    defp count_packets(path) do
      {out, 0} =
        System.cmd(
          "ffprobe",
          ~w(-v error -count_packets -select_streams v:0
             -show_entries stream=nb_read_packets -of csv=p=0) ++ [path]
        )

      out |> String.trim() |> String.to_integer()
    end

    test "the video length cap holds for what is stored, not what the container declares" do
      media = Application.fetch_env!(:goodmao2, Goodmao2.Media)
      Application.put_env(:goodmao2, Goodmao2.Media, Keyword.put(media, :max_video_seconds, 1))
      on_exit(fn -> Application.put_env(:goodmao2, Goodmao2.Media, media) end)

      src = make_lying_webm(1000)
      assert count_packets(src) == 30

      assert {:ok, purified} = Purifier.purify(src)
      on_exit(fn -> File.rm(purified.path) end)

      # 1 s at 10 fps, not the 3 s the clusters actually carry.
      assert count_packets(purified.path) <= 11
    end
  end
end
