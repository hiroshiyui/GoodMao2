defmodule Goodmao2Web.MediaComponents do
  @moduledoc """
  Rendering for life-log media (ADR-0005), shared by the timeline (`PetLive.Show`) and the
  entry page (`PetLive.LogEntry`).

  Every asset is served from an authorized endpoint — never a static path — so the
  grant/visibility checks apply to the bytes too. Authenticated views use `/media/:id`; the
  anonymous shared-entry page passes a `share_token` so the bytes flow through the token-gated
  `/entries/shared/:token/media/:id` instead (ADR-0004). Images link out to their full size;
  videos render an inline player.
  """
  use Phoenix.Component
  use Gettext, backend: Goodmao2Web.Gettext

  import Goodmao2Web.CoreComponents, only: [icon: 1]
  import Goodmao2Web.Helpers, only: [media_alt: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: Goodmao2Web.Endpoint,
    router: Goodmao2Web.Router,
    statics: Goodmao2Web.static_paths()

  attr :assets, :list, required: true
  attr :class, :string, default: "timeline-media mt-2 flex flex-wrap gap-2"
  attr :media_class, :string, default: "max-h-32"
  # When set, serve bytes through the anonymous token-gated route instead of the authed one.
  attr :share_token, :string, default: nil

  def media_grid(assigns) do
    ~H"""
    <div class={@class}>
      <div :for={asset <- @assets} id={"media-#{asset.id}"} class="media-item">
        <a
          :if={asset.kind == "image"}
          href={asset_src(asset, @share_token)}
          target="_blank"
          rel="noopener"
        >
          <img
            src={asset_src(asset, @share_token)}
            alt={media_alt(asset)}
            loading="lazy"
            class={["rounded border border-base-200", @media_class]}
          />
        </a>
        <video
          :if={asset.kind == "video"}
          src={asset_src(asset, @share_token)}
          controls
          preload="metadata"
          class={["rounded border border-base-200", @media_class]}
        />
      </div>
    </div>
    """
  end

  defp asset_src(asset, nil), do: ~p"/media/#{asset.id}"
  defp asset_src(asset, token), do: ~p"/entries/shared/#{token}/media/#{asset.id}"

  @doc """
  The selected-files list of a media upload form: one row per file with a live progress bar
  (`entry.progress` streams in while the chunks upload), a cancel button firing `cancel_event`
  with the entry ref, and per-file + form-level upload errors. Shared by the QuickLog form
  (`PetLive.Show`) and the entry page's media form (`PetLive.LogEntry`).
  """
  attr :upload, Phoenix.LiveView.UploadConfig, required: true
  attr :cancel_event, :string, required: true

  def upload_file_list(assigns) do
    ~H"""
    <ul class="space-y-1">
      <li
        :for={entry <- @upload.entries}
        id={"upload-entry-#{entry.ref}"}
        class="flex items-center gap-2 text-sm"
      >
        <span class="min-w-0 flex-1 truncate">{entry.client_name}</span>
        <progress
          class="progress progress-primary w-24 shrink-0"
          value={entry.progress}
          max="100"
          aria-label={gettext("Upload progress for %{name}", name: entry.client_name)}
        >
          {entry.progress}%
        </progress>
        <button
          type="button"
          phx-click={@cancel_event}
          phx-value-ref={entry.ref}
          class="btn btn-ghost btn-xs"
          aria-label={gettext("Remove file")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
        <span :for={err <- upload_errors(@upload, entry)} class="text-error text-xs">
          {upload_error_label(err)}
        </span>
      </li>
    </ul>
    <p :for={err <- upload_errors(@upload)} class="text-error text-xs">
      {upload_error_label(err)}
    </p>
    """
  end

  defp upload_error_label(:too_large), do: gettext("File is too large.")
  defp upload_error_label(:too_many_files), do: gettext("Too many files.")
  defp upload_error_label(:not_accepted), do: gettext("That file type isn't accepted.")
  defp upload_error_label(_), do: gettext("That file can't be used.")
end
