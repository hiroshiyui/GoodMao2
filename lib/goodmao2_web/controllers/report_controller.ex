defmodule Goodmao2Web.ReportController do
  @moduledoc """
  Serves a health-summary report to an anonymous holder of an unexpired share link.

  The only gate is the token: `Reports.fetch_report_by_token/1` returns the live report
  only for a matching, non-expired, non-revoked, non-deleted row. A bad, expired, or revoked
  token is reported as `not_found` — existence-hidden, exactly like the media endpoint. The
  frozen snapshot never contains private entries, so no authorization is needed to render it.
  """
  use Goodmao2Web, :controller

  alias Goodmao2.Reports

  def show(conn, %{"token" => token}) do
    case Reports.fetch_report_by_token(token) do
      nil ->
        conn |> put_status(:not_found) |> put_view(Goodmao2Web.ErrorHTML) |> render(:"404")

      report ->
        conn
        |> assign(:page_title, gettext("Health summary"))
        |> assign(:report, report)
        |> render(:show)
    end
  end
end
