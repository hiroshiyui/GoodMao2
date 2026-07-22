defmodule Goodmao2Web.AvatarComponents do
  @moduledoc """
  Round-masked profile images for users and pets (ADR-0020).

  A single `<.avatar>` renders an owner's purified image — served from the authorized,
  IDOR-hidden `/avatars/<owner_type>/<owner_id>` endpoint (never a static path) — under a circular
  mask (`rounded-full object-cover`), or a neutral initials disc when the owner has no ready
  avatar. Callers pass the owner's already-loaded avatar `meta` (`%{status, version}` from
  `Media.Avatars.get_avatar/2` or `metas_for/2`) so lists render without an N+1.
  """
  use Phoenix.Component
  use Gettext, backend: Goodmao2Web.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: Goodmao2Web.Endpoint,
    router: Goodmao2Web.Router,
    statics: Goodmao2Web.static_paths()

  @sizes %{
    sm: "size-8 text-xs",
    md: "size-10 text-sm",
    lg: "size-16 text-lg",
    xl: "size-24 text-3xl"
  }

  attr :owner_type, :string, required: true, values: ~w(user pet)
  attr :owner_id, :any, required: true
  attr :name, :string, default: nil, doc: "for the alt text and the initials fallback"
  attr :meta, :map, default: nil, doc: "%{status, version} from Media.Avatars; nil ⇒ fallback"
  attr :size, :atom, default: :md, values: [:sm, :md, :lg, :xl]
  attr :id, :string, default: nil, doc: "override the element id (e.g. when rendered twice)"
  attr :class, :string, default: nil

  def avatar(assigns) do
    assigns =
      assigns
      |> assign(:ready?, match?(%{status: "ready"}, assigns.meta))
      |> assign(:size_class, Map.fetch!(@sizes, assigns.size))
      |> assign_new(:dom_id, fn ->
        assigns.id || "avatar-#{assigns.owner_type}-#{assigns.owner_id}"
      end)

    ~H"""
    <span
      id={@dom_id}
      class={[
        "inline-flex shrink-0 items-center justify-center overflow-hidden rounded-full",
        @size_class,
        @class
      ]}
    >
      <img
        :if={@ready?}
        src={avatar_src(@owner_type, @owner_id, @meta[:version])}
        alt={avatar_alt(@name)}
        class="size-full object-cover"
        loading="lazy"
      />
      <span
        :if={!@ready?}
        class="flex size-full items-center justify-center bg-base-300 font-semibold text-base-content/70"
        aria-label={avatar_alt(@name)}
      >
        {initials(@name)}
      </span>
    </span>
    """
  end

  # `?v=` cache-busts when the avatar is replaced (the object path is stable per owner).
  defp avatar_src("user", id, version), do: ~p"/avatars/user/#{id}?#{[v: version || 0]}"
  defp avatar_src("pet", id, version), do: ~p"/avatars/pet/#{id}?#{[v: version || 0]}"

  defp avatar_alt(nil), do: gettext("Profile photo")
  defp avatar_alt(""), do: gettext("Profile photo")
  defp avatar_alt(name), do: gettext("%{name}'s profile photo", name: name)

  defp initials(name) do
    case name |> to_string() |> String.trim() do
      "" -> "?"
      trimmed -> trimmed |> String.first() |> String.upcase()
    end
  end
end
