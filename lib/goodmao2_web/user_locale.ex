defmodule Goodmao2Web.UserLocale do
  @moduledoc """
  LiveView `on_mount` hook that applies the request locale (mirrored into the session by
  `Goodmao2Web.Plugs.Locale`) to the LiveView process, so `gettext()` inside LiveViews
  renders in the chosen language. Runs on both the dead render and the connected mount.
  """
  alias Goodmao2Web.Locale

  def on_mount(:put_locale, _params, session, socket) do
    locale =
      if is_binary(session["locale"]) and Locale.known?(session["locale"]),
        do: session["locale"],
        else: Locale.default()

    Gettext.put_locale(Goodmao2Web.Gettext, locale)
    {:cont, socket}
  end
end
