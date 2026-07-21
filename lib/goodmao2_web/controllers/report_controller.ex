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

  def show(conn, %{"token" => token} = params) do
    case Reports.fetch_report_by_token(token) do
      nil ->
        conn |> put_status(:not_found) |> put_view(Goodmao2Web.ErrorHTML) |> render(:"404")

      report ->
        conn
        |> assign(:page_title, gettext("Health summary"))
        |> assign(:report, report)
        |> assign(:page, parse_page(params["page"]))
        |> assign(:base_path, ~p"/reports/shared/#{token}")
        |> render(:show)
    end
  end

  # A 1-based page number from the query string, defaulting to 1 on anything unparseable.
  defp parse_page(value) do
    case value && Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end
end
