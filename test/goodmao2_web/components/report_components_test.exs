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
end
