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
end
