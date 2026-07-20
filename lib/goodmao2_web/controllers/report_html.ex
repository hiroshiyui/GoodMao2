defmodule Goodmao2Web.ReportHTML do
  @moduledoc """
  HTML for the anonymous, tokenized health-summary report page (print-friendly).
  """
  use Goodmao2Web, :html

  embed_templates "report_html/*"
end
