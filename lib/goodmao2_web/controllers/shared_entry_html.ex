defmodule Goodmao2Web.SharedEntryHTML do
  @moduledoc """
  HTML for the anonymous, tokenized single-entry share page (ADR-0004).
  """
  use Goodmao2Web, :html

  embed_templates "shared_entry_html/*"

  @doc false
  def flag_class(:urgent), do: "badge-error"
  def flag_class(:watch), do: "badge-warning"
  def flag_class(_), do: "badge-ghost"
end
