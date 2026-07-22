defmodule Goodmao2Web.ReportComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias Goodmao2Web.ReportComponents

  defp content(n) do
    entries =
      for i <- 1..n do
        %{
          "type" => "food",
          "data" => %{"amount" => "full"},
          "occurred_at" => "2026-07-#{String.pad_leading(to_string(i), 2, "0")}T08:00:00Z",
          "note" => "entry #{i}"
        }
      end

    %{"entries" => entries, "pet" => %{"name" => "Mochi", "weight_unit" => "kilograms"}}
  end

  defp render_body(opts) do
    render_component(
      &ReportComponents.report_body/1,
      Keyword.merge(
        [
          content: content(Keyword.fetch!(opts, :n)),
          period_start: ~D[2026-07-01],
          period_end: ~D[2026-07-31],
          base_path: "/reports/shared/tok"
        ],
        Keyword.drop(opts, [:n])
      )
    )
  end

  describe "report_body paging (roadmap §8)" do
    test "a short report shows no pager and all entries" do
      html = render_body(n: 3, page: 1, page_size: 100)
      refute html =~ "report-pager"
      assert html =~ "entry 1"
      assert html =~ "entry 3"
    end

    test "a long report pages by the given size with the right slice and controls" do
      # 5 entries, page size 2 → page 2 shows entries 3–4, with Prev (page 1) and Next (page 3).
      html = render_body(n: 5, page: 2, page_size: 2)

      assert html =~ "report-pager"
      assert html =~ "3–4 of 5"
      assert html =~ "?page=1"
      assert html =~ "?page=3"
      assert html =~ "entry 3"
      assert html =~ "entry 4"
      refute html =~ "entry 1"
      refute html =~ "entry 5"

      # The Entries total still reflects the whole report, not the page.
      assert html =~ "report-meta"
    end

    test "the last page hides Next" do
      html = render_body(n: 5, page: 3, page_size: 2)
      assert html =~ "5–5 of 5"
      refute html =~ "?page=4"
    end
  end

  describe "weight_chart daily aggregation" do
    test "collapses same-day readings into one evenly-spaced mean point per day" do
      # Two weigh-ins on 07-01 (mean 4100) and one on 07-03 → two daily points, evenly spaced
      # across the 6..634 track (not one point per raw reading).
      series = [
        %{at: ~U[2026-07-01 06:00:00Z], grams: 4000},
        %{at: ~U[2026-07-01 18:00:00Z], grams: 4200},
        %{at: ~U[2026-07-03 09:00:00Z], grams: 4300}
      ]

      html = render_component(&ReportComponents.weight_chart/1, series: series, unit: "grams")

      assert [_, points] = Regex.run(~r/<polyline[^>]*points="([^"]+)"/, html)
      xs = points |> String.split(" ") |> Enum.map(&(&1 |> String.split(",") |> hd()))
      assert xs == ["6.0", "634.0"]

      # The 07-01 pair is shown as its mean (4100), not as the individual 4000/4200 readings.
      assert html =~ "4100 g"
      refute html =~ "4000 g"
      refute html =~ "4200 g"
    end

    test "draws faint x/y scale lines with the x-axis strictly partitioned by day" do
      # 07-01 → 07-03 spans 3 calendar days (07-01, 07-02, 07-03), even though 07-02 has no data.
      series = [
        %{at: ~U[2026-07-01 06:00:00Z], grams: 4000},
        %{at: ~U[2026-07-03 09:00:00Z], grams: 4300}
      ]

      html = render_component(&ReportComponents.weight_chart/1, series: series, unit: "grams")

      # 5 horizontal rules + one vertical rule per calendar day (3 days) = 8 <line> elements.
      assert length(Regex.scan(~r/<line\b/, html)) == 8
      assert html =~ "text-base-content/10"
    end

    test "positions points by calendar-day offset so empty days become real gaps" do
      # A lone day, then a two-day gap, then two consecutive days → offsets 0, 3, 4 over a 4-day span.
      series = [
        %{at: ~U[2026-07-01 12:00:00Z], grams: 4000},
        %{at: ~U[2026-07-04 12:00:00Z], grams: 4100},
        %{at: ~U[2026-07-05 12:00:00Z], grams: 4200}
      ]

      html = render_component(&ReportComponents.weight_chart/1, series: series, unit: "grams")

      assert [_, points] = Regex.run(~r/<polyline[^>]*points="([^"]+)"/, html)
      xs = points |> String.split(" ") |> Enum.map(&(&1 |> String.split(",") |> hd()))
      # 6 + offset/4 * 628: day 0 → 6.0, day 3 → 477.0, day 4 → 634.0.
      assert xs == ["6.0", "477.0", "634.0"]
    end

    test "keeps per-day dots for a short history" do
      series =
        for d <- 1..5,
            do: %{
              at: DateTime.new!(Date.new!(2026, 7, d), ~T[09:00:00], "Etc/UTC"),
              grams: 4000 + d
            }

      html = render_component(&ReportComponents.weight_chart/1, series: series, unit: "grams")

      # 5 per-day dots + the latest-point marker = 6 circles.
      assert length(Regex.scan(~r/<circle\b/, html)) == 6
    end

    test "drops the crowded per-day dots over a long history, keeping the line + latest marker" do
      series =
        for d <- 1..60,
            do: %{
              at: DateTime.new!(Date.new!(2026, 7, 1) |> Date.add(d), ~T[09:00:00], "Etc/UTC"),
              grams: 4000 + d
            }

      html = render_component(&ReportComponents.weight_chart/1, series: series, unit: "grams")

      # 60 days > threshold → only the latest-point marker circle remains; the polyline still spans.
      assert length(Regex.scan(~r/<circle\b/, html)) == 1
      assert html =~ "<polyline"
    end

    test "leaves the sr-only table complete for a short history" do
      series =
        for d <- 1..5,
            do: %{
              at: DateTime.new!(Date.new!(2026, 7, d), ~T[09:00:00], "Etc/UTC"),
              grams: 4000 + d
            }

      html = render_component(&ReportComponents.weight_chart/1, series: series, unit: "grams")

      # 1 header row + 5 data rows; caption is the plain label (not the sampled note).
      assert length(Regex.scan(~r/<tr\b/, html)) == 6
      refute html =~ "evenly sampled"
    end

    test "caps and evenly samples the sr-only table for a long history" do
      series =
        for d <- 1..100,
            do: %{
              at: DateTime.new!(Date.new!(2026, 7, 1) |> Date.add(d), ~T[09:00:00], "Etc/UTC"),
              grams: 4000 + d
            }

      html = render_component(&ReportComponents.weight_chart/1, series: series, unit: "grams")

      # 100 days → sampled to at most 45 rows (+ the header row), not 100.
      data_rows = length(Regex.scan(~r/<tr\b/, html)) - 1
      assert data_rows <= 45
      assert html =~ "of 100 days"
      assert html =~ "evenly sampled"

      # The endpoints are always kept: first day (07-02) and last day (10-09).
      assert html =~ "2026-07-02"
      assert html =~ "2026-10-09"
    end
  end
end
