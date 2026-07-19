defmodule Goodmao2Web.CalendarGridTest do
  use ExUnit.Case, async: true

  alias Goodmao2Web.CalendarGrid

  describe "month_of/1 and add_months/2" do
    test "month_of normalises to the first of the month" do
      assert CalendarGrid.month_of(~D[2026-07-19]) == ~D[2026-07-01]
    end

    test "add_months carries across year boundaries" do
      assert CalendarGrid.add_months(~D[2026-01-10], -1) == ~D[2025-12-01]
      assert CalendarGrid.add_months(~D[2026-12-31], 1) == ~D[2027-01-01]
    end
  end

  describe "month_grid/1" do
    test "is always a 6×7 grid starting on a Sunday" do
      grid = CalendarGrid.month_grid(~D[2026-07-01])

      assert length(grid) == 6
      assert Enum.all?(grid, &(length(&1) == 7))

      first = grid |> List.first() |> List.first()
      assert Date.day_of_week(first, :sunday) == 1
      # July 1 2026 is a Wednesday, so the grid leads in from the prior Sunday.
      assert first == ~D[2026-06-28]
      assert List.last(List.last(grid)) == ~D[2026-08-08]
    end

    test "contains every day of the target month" do
      days =
        CalendarGrid.month_grid(~D[2026-02-01])
        |> List.flatten()
        |> Enum.filter(&(&1.month == 2))
        |> Enum.map(& &1.day)

      assert Enum.min(days) == 1
      # 2026 is not a leap year.
      assert Enum.max(days) == 28
    end
  end

  describe "grid_range/1" do
    test "spans the whole visible grid as inclusive UTC bounds" do
      {from, to} = CalendarGrid.grid_range(~D[2026-07-01])

      assert from == ~U[2026-06-28 00:00:00.000Z]
      assert DateTime.to_date(to) == ~D[2026-08-08]
      assert to.hour == 23 and to.minute == 59
      assert from.time_zone == "Etc/UTC"
    end
  end
end
