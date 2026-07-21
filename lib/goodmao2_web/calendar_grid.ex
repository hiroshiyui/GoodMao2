defmodule Goodmao2Web.CalendarGrid do
  @moduledoc """
  Pure helpers for the month-grid ("calendar") view of a pet's timeline.

  Days are bucketed in the **viewer's timezone** (ADR-0018), matching how the timeline renders
  each entry's time server-side (see `Goodmao2Web.Helpers.format_datetime/1`): a log's day cell
  is the same day shown on its list row, so the two views never disagree. The bucketing itself
  lives in `PetLive.Show` (which knows the active zone); `grid_range/1` here just widens the UTC
  query window by a day on each side so entries near a local-midnight edge are still fetched to
  bucket (any IANA offset is < 24h from UTC).

  The three shipping locales (en / zh_TW / ja_JP) all conventionally start the week on
  Sunday, so the grid is Sunday-first.
  """

  @doc "The first day of the month containing `date` (a `Date`)."
  def month_of(%Date{} = date), do: Date.beginning_of_month(date)

  @doc "Shift a month by `delta` months, normalised to the first of the month."
  def add_months(%Date{} = month_first, delta) do
    month_first |> Date.beginning_of_month() |> Date.shift(month: delta)
  end

  @doc """
  The month laid out as a fixed 6×7 grid of `Date`s, padded with the trailing days of the
  previous month and the leading days of the next so every week is whole. Always 6 rows so
  the grid height doesn't jump between months. Sunday-first.
  """
  def month_grid(%Date{} = month_first) do
    first = Date.beginning_of_month(month_first)
    # Date.day_of_week/2 with :sunday returns 1 (Sun) .. 7 (Sat); lead is days before the 1st.
    lead = Date.day_of_week(first, :sunday) - 1
    start = Date.add(first, -lead)

    for w <- 0..5 do
      for d <- 0..6, do: Date.add(start, w * 7 + d)
    end
  end

  @doc """
  The inclusive `{from, to}` UTC `DateTime` bounds spanning the whole visible grid — for the
  `Logs.list_entries/3` `:from`/`:to` query. Because the grid spills into adjacent months, this
  covers the padding days too, and it is padded by an extra day on each side so entries whose
  **local** day falls in the grid but whose UTC instant lands just outside it are still fetched
  (viewer-timezone bucketing, ADR-0018).
  """
  def grid_range(%Date{} = month_first) do
    grid = month_grid(month_first)
    first = grid |> List.first() |> List.first() |> Date.add(-1)
    last = grid |> List.last() |> List.last() |> Date.add(1)

    {DateTime.new!(first, ~T[00:00:00.000], "Etc/UTC"),
     DateTime.new!(last, ~T[23:59:59.999999], "Etc/UTC")}
  end
end
