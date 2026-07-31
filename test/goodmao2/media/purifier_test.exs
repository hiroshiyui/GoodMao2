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
end
