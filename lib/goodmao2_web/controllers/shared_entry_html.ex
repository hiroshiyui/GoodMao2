defmodule Goodmao2Web.SharedEntryHTML do
  @moduledoc """
  HTML for the anonymous, tokenized single-entry share page (ADR-0004).
  """
  use Goodmao2Web, :html

  embed_templates "shared_entry_html/*"
end
