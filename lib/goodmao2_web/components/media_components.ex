defmodule Goodmao2Web.MediaComponents do
  @moduledoc """
  Rendering for life-log media (ADR-0005), shared by the timeline (`PetLive.Show`) and the
  entry page (`PetLive.LogEntry`).

  Every asset is served from the authorized `/media/:id` endpoint — never a static path — so
  the grant/visibility checks apply to the bytes too. Images link out to their full size;
  videos render an inline player.
  """
  use Phoenix.Component
  use Gettext, backend: Goodmao2Web.Gettext

  import Goodmao2Web.Helpers, only: [media_alt: 1]

  use Phoenix.VerifiedRoutes,
    endpoint: Goodmao2Web.Endpoint,
    router: Goodmao2Web.Router,
    statics: Goodmao2Web.static_paths()

  attr :assets, :list, required: true
  attr :class, :string, default: "timeline-media mt-2 flex flex-wrap gap-2"
  attr :media_class, :string, default: "max-h-32"

  def media_grid(assigns) do
    ~H"""
    <div class={@class}>
      <div :for={asset <- @assets} id={"media-#{asset.id}"} class="media-item">
        <a :if={asset.kind == "image"} href={~p"/media/#{asset.id}"} target="_blank" rel="noopener">
          <img
            src={~p"/media/#{asset.id}"}
            alt={media_alt(asset)}
            loading="lazy"
            class={["rounded border border-base-200", @media_class]}
          />
        </a>
        <video
          :if={asset.kind == "video"}
          src={~p"/media/#{asset.id}"}
          controls
          preload="metadata"
          class={["rounded border border-base-200", @media_class]}
        />
      </div>
    </div>
    """
  end
end
