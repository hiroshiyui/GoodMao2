defmodule Goodmao2Web.ShareComponents do
  @moduledoc """
  A share link the owner can hand on: the URL in a read-only field, a **Copy** button, a
  **Share** button where the platform has a share sheet, and a polite status line that says
  what happened. Used by the entry share link (`PetLive.LogEntry`) and the report share link
  (`PetLive.Reports`) — the latter is shown only once, so a copy that fails silently loses it.

  The behaviour lives in `assets/js/clipboard.js` (the `Clipboard` and `WebShare` hooks). Every
  word the client shows or announces is server-rendered gettext passed in `data-*`, so the
  client never falls back to English. The status line is `role="status"` and
  `phx-update="ignore"`: it exists before anything is written into it (a live region created at
  the moment of the message is often not announced), and a LiveView patch cannot wipe the
  message while it is still being read.

  The Share button renders `hidden` and the hook reveals it only when `navigator.share` exists;
  `JS.ignore_attributes/1` keeps later patches from hiding it again.
  """
  use Phoenix.Component
  use Gettext, backend: Goodmao2Web.Gettext

  import Goodmao2Web.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true, doc: "prefix for the stable child ids (`<id>-url`, …)"
  attr :url, :string, required: true
  attr :label, :string, required: true, doc: "accessible name of the URL field"
  attr :share_title, :string, default: nil, doc: "title offered to the platform share sheet"

  def share_link(assigns) do
    ~H"""
    <div id={"#{@id}-link"} class="share-link space-y-1">
      <div class="flex flex-wrap items-center gap-2">
        <input
          id={"#{@id}-url"}
          type="text"
          readonly
          value={@url}
          class="share-link-url input input-bordered input-sm min-w-0 flex-1"
          aria-label={@label}
        />
        <button
          type="button"
          id={"#{@id}-copy"}
          phx-hook="Clipboard"
          data-clipboard-target={"##{@id}-url"}
          data-clipboard-status={"##{@id}-status"}
          data-copied-label={gettext("Link copied.")}
          data-copy-failed-label={
            gettext("Couldn't copy automatically. The link is selected — copy it from there.")
          }
          class="share-link-copy btn btn-sm btn-primary"
        >
          <.icon name="hero-clipboard-document" class="size-4" /> {gettext("Copy")}
        </button>
        <button
          type="button"
          id={"#{@id}-native"}
          phx-hook="WebShare"
          phx-mounted={JS.ignore_attributes(["hidden"])}
          hidden
          data-share-url={@url}
          data-share-title={@share_title}
          data-clipboard-target={"##{@id}-url"}
          data-clipboard-status={"##{@id}-status"}
          data-copied-label={gettext("Link copied.")}
          data-copy-failed-label={
            gettext("Couldn't copy automatically. The link is selected — copy it from there.")
          }
          class="share-link-native btn btn-sm btn-ghost"
        >
          <.icon name="hero-share" class="size-4" /> {gettext("Share")}
        </button>
      </div>
      <p
        id={"#{@id}-status"}
        role="status"
        phx-update="ignore"
        class="share-link-status min-h-5 text-sm"
      >
      </p>
    </div>
    """
  end
end
