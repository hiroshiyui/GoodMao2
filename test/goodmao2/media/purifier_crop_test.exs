defmodule Goodmao2.Media.PurifierCropTest do
  # async: false — shells out to ffmpeg/ffprobe and reads Limits from the DB.
  use Goodmao2.DataCase, async: false

  alias Goodmao2.Media.Purifier

  # A solid non-square PNG (width x height) via ffmpeg.
  defp make_png(w, h) do
    path = Path.join(System.tmp_dir!(), "gm_crop_#{System.unique_integer([:positive])}.png")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-hide_banner -v error -f lavfi -i) ++
          ["color=c=red:s=#{w}x#{h}"] ++ ~w(-frames:v 1 -y) ++ [path]
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp dims(path) do
    {out, 0} =
      System.cmd(
        "ffprobe",
        ~w(-v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0) ++ [path]
      )

    [w, h] = out |> String.trim() |> String.split(",")
    {String.to_integer(w), String.to_integer(h)}
  end

  test "a normalized square crop yields a square output in input pixels" do
    src = make_png(40, 20)

    # Left half of a 40x20 image: 20px wide (iw*0.5) by 20px tall (ih*1.0) — a square.
    {:ok, purified} =
      Purifier.purify(src, crop: %{"x" => 0.0, "y" => 0.0, "w" => 0.5, "h" => 1.0})

    on_exit(fn -> File.rm(purified.path) end)

    assert dims(purified.path) == {20, 20}
  end

  test "a sub-rectangle crop maps to the expected pixel region" do
    src = make_png(100, 100)

    {:ok, purified} =
      Purifier.purify(src, crop: %{"x" => 0.25, "y" => 0.25, "w" => 0.5, "h" => 0.5})

    on_exit(fn -> File.rm(purified.path) end)
    assert dims(purified.path) == {50, 50}
  end

  test "no crop leaves the full frame" do
    src = make_png(40, 20)
    {:ok, purified} = Purifier.purify(src)
    on_exit(fn -> File.rm(purified.path) end)
    assert dims(purified.path) == {40, 20}
  end

  test "an unusable or missing crop is ignored (full frame), never crashes" do
    src = make_png(40, 20)

    for bad <- [
          %{"x" => "nope", "y" => 0.0, "w" => 0.5, "h" => 0.5},
          %{"x" => 0.0, "y" => 0.0, "w" => 0.0, "h" => 0.0},
          %{"nonsense" => true},
          nil
        ] do
      {:ok, purified} = Purifier.purify(src, crop: bad)
      on_exit(fn -> File.rm(purified.path) end)
      assert dims(purified.path) == {40, 20}
    end
  end

  test "an out-of-range crop is clamped to a valid sub-rectangle, not rejected" do
    src = make_png(40, 20)
    # x=-1 → 0, w=2 → 1 (full width), h=0.5 → half height: a valid 40x10 crop.
    {:ok, purified} =
      Purifier.purify(src, crop: %{"x" => -1.0, "y" => 0.0, "w" => 2.0, "h" => 0.5})

    on_exit(fn -> File.rm(purified.path) end)
    assert dims(purified.path) == {40, 10}
  end
end
