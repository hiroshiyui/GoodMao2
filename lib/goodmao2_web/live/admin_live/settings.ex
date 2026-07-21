defmodule Goodmao2Web.AdminLive.Settings do
  @moduledoc """
  Admin-only system settings. Currently: the Web Push (VAPID) keypair (ADR-0011 Stage 2).

  An administrator generates the keypair here — the public key is handed to browsers, the
  private key is encrypted (`WebPush.VapidVault`) and stored in the `settings` table. A
  sibling of `AdminLive`, gated by the same `:require_admin` on_mount (non-admins are
  silently sent home, IDOR-hidden).
  """
  use Goodmao2Web, :live_view

  on_mount {Goodmao2Web.UserAuth, :require_admin}

  alias Goodmao2.Media.Limits
  alias Goodmao2.Notifications.WebPush
  alias Goodmao2.Settings
  alias Goodmao2.Timezone

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("System settings"))
     |> load_vapid()
     |> load_timezone()
     |> load_media_limits()}
  end

  @impl true
  def handle_event("generate_vapid_keys", _params, socket) do
    {public_key, encrypted_private} = WebPush.generate_keypair()

    with {:ok, _} <- Settings.put("vapid_public_key", public_key),
         {:ok, _} <- Settings.put("vapid_private_key_encrypted", Base.encode64(encrypted_private)) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         gettext("New Web Push keys generated. Existing subscriptions must re-subscribe.")
       )
       |> load_vapid()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not save the keys."))}
    end
  end

  def handle_event("save_subject", %{"vapid" => %{"subject" => subject}}, socket) do
    case Settings.put("vapid_subject", String.trim(subject)) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, gettext("Contact saved.")) |> load_vapid()}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Could not save the contact."))}
    end
  end

  def handle_event("save_timezone", %{"tz" => %{"timezone" => tz}}, socket) do
    if Timezone.known?(tz) do
      case Settings.put("default_timezone", tz) do
        {:ok, _} ->
          {:noreply,
           socket |> put_flash(:info, gettext("System timezone saved.")) |> load_timezone()}

        _ ->
          {:noreply, put_flash(socket, :error, gettext("Could not save the timezone."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("That is not a valid timezone."))}
    end
  end

  def handle_event("save_media_limits", %{"media" => params}, socket) do
    case parse_media_limits(params) do
      {:ok, values} ->
        Enum.each(values, fn {field, value} ->
          Settings.put(Limits.setting_key(field), Integer.to_string(value))
        end)

        {:noreply,
         socket |> put_flash(:info, gettext("Media limits saved.")) |> load_media_limits()}

      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Every media limit must be a whole number of 0 or more (0 means no limit).")
         )}
    end
  end

  # Parse every field to a non-negative integer, all-or-nothing (a single bad value rejects the
  # whole form, so a partial save can never leave the limits inconsistent).
  defp parse_media_limits(params) do
    Enum.reduce_while(Limits.fields(), {:ok, []}, fn field, {:ok, acc} ->
      case params |> Map.get(Atom.to_string(field), "") |> String.trim() |> Integer.parse() do
        {n, ""} when n >= 0 -> {:cont, {:ok, [{field, n} | acc]}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp load_vapid(socket) do
    socket
    |> assign(:vapid_public_key, WebPush.public_key())
    |> assign(:vapid_configured, WebPush.vapid_configured?())
    |> assign(:subject_form, to_form(%{"subject" => WebPush.subject()}, as: :vapid))
  end

  defp load_timezone(socket) do
    assign(socket, :timezone_form, to_form(%{"timezone" => Timezone.system_default()}, as: :tz))
  end

  defp load_media_limits(socket) do
    values =
      Map.new(Limits.fields(), fn field ->
        {Atom.to_string(field), to_string(Limits.get(field))}
      end)

    assign(socket, :media_form, to_form(values, as: :media))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
    >
      <section
        id="admin-settings-section"
        aria-labelledby="admin-settings-heading"
        class="mx-auto max-w-xl"
      >
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/admin"}
            id="admin-settings-back"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Back")}
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 id="admin-settings-heading" class="text-2xl font-semibold">
            {gettext("System settings")}
          </h1>
        </div>

        <section
          id="vapid-card"
          aria-labelledby="vapid-heading"
          class="card card-border bg-base-100 mt-6"
        >
          <div class="card-body space-y-3 p-4">
            <div class="flex items-center justify-between gap-2">
              <h2 id="vapid-heading" class="text-lg font-semibold">{gettext("Web Push (VAPID)")}</h2>
              <span
                id="vapid-status"
                class={["badge badge-sm", (@vapid_configured && "badge-success") || "badge-ghost"]}
              >
                {if @vapid_configured, do: gettext("Configured"), else: gettext("Not configured")}
              </span>
            </div>

            <p class="text-base-content/60 text-sm">
              {gettext(
                "Web Push lets followers receive notifications with GoodMao closed. Generate a keypair to enable it."
              )}
            </p>

            <div :if={@vapid_public_key} class="form-control">
              <label for="vapid-public-key" class="label">
                <span class="label-text">{gettext("Public key")}</span>
              </label>
              <input
                id="vapid-public-key"
                type="text"
                readonly
                value={@vapid_public_key}
                class="input input-bordered input-sm font-mono text-xs"
              />
            </div>

            <.form for={@subject_form} id="vapid-subject-form" phx-submit="save_subject">
              <.input
                field={@subject_form[:subject]}
                type="text"
                label={gettext("Contact (mailto:)")}
              />
              <.button type="submit" id="vapid-subject-submit" class="btn btn-sm mt-2">
                {gettext("Save contact")}
              </.button>
            </.form>

            <button
              type="button"
              id="generate-vapid-keys"
              phx-click="generate_vapid_keys"
              data-confirm={
                gettext(
                  "Regenerating the keys invalidates every existing push subscription — users will need to re-enable notifications. Continue?"
                )
              }
              class="btn btn-primary btn-sm w-fit"
              phx-disable-with={gettext("Generating…")}
            >
              {if @vapid_configured, do: gettext("Regenerate keys"), else: gettext("Generate keys")}
            </button>
          </div>
        </section>

        <section
          id="timezone-card"
          aria-labelledby="timezone-heading"
          class="card card-border bg-base-100 mt-6"
        >
          <div class="card-body space-y-3 p-4">
            <h2 id="timezone-heading" class="text-lg font-semibold">
              {gettext("System timezone")}
            </h2>
            <p class="text-base-content/60 text-sm">
              {gettext(
                "The default timezone for displaying and entering times, used for anyone who has not set their own preference."
              )}
            </p>

            <.form for={@timezone_form} id="timezone-form" phx-submit="save_timezone">
              <.input
                field={@timezone_form[:timezone]}
                type="select"
                id="system-timezone-select"
                label={gettext("Default timezone")}
                options={Timezone.all()}
              />
              <.button type="submit" id="timezone-submit" class="btn btn-sm mt-2">
                {gettext("Save timezone")}
              </.button>
            </.form>
          </div>
        </section>

        <section
          id="media-limits-card"
          aria-labelledby="media-limits-heading"
          class="card card-border bg-base-100 mt-6"
        >
          <div class="card-body space-y-3 p-4">
            <h2 id="media-limits-heading" class="text-lg font-semibold">
              {gettext("Media upload limits")}
            </h2>
            <p class="text-base-content/60 text-sm">
              {gettext(
                "Caps applied to purified LifeLog photos and videos. Sizes are in bytes and dimensions in pixels; set any field to 0 to lift that limit."
              )}
            </p>

            <.form
              for={@media_form}
              id="media-limits-form"
              phx-submit="save_media_limits"
              class="space-y-4"
            >
              <fieldset class="space-y-2">
                <legend class="text-sm font-medium">{gettext("Maximum file size (bytes)")}</legend>
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@media_form[:max_image_bytes]}
                    type="number"
                    min="0"
                    label={gettext("Image")}
                  />
                  <.input
                    field={@media_form[:max_video_bytes]}
                    type="number"
                    min="0"
                    label={gettext("Video")}
                  />
                </div>
              </fieldset>

              <fieldset class="space-y-2">
                <legend class="text-sm font-medium">
                  {gettext("Image dimensions (pixels)")}
                </legend>
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@media_form[:min_image_width]}
                    type="number"
                    min="0"
                    label={gettext("Min width")}
                  />
                  <.input
                    field={@media_form[:min_image_height]}
                    type="number"
                    min="0"
                    label={gettext("Min height")}
                  />
                  <.input
                    field={@media_form[:max_image_width]}
                    type="number"
                    min="0"
                    label={gettext("Max width")}
                  />
                  <.input
                    field={@media_form[:max_image_height]}
                    type="number"
                    min="0"
                    label={gettext("Max height")}
                  />
                </div>
              </fieldset>

              <fieldset class="space-y-2">
                <legend class="text-sm font-medium">
                  {gettext("Video dimensions (pixels)")}
                </legend>
                <div class="grid grid-cols-2 gap-3">
                  <.input
                    field={@media_form[:min_video_width]}
                    type="number"
                    min="0"
                    label={gettext("Min width")}
                  />
                  <.input
                    field={@media_form[:min_video_height]}
                    type="number"
                    min="0"
                    label={gettext("Min height")}
                  />
                  <.input
                    field={@media_form[:max_video_width]}
                    type="number"
                    min="0"
                    label={gettext("Max width")}
                  />
                  <.input
                    field={@media_form[:max_video_height]}
                    type="number"
                    min="0"
                    label={gettext("Max height")}
                  />
                </div>
              </fieldset>

              <.button type="submit" id="media-limits-submit" class="btn btn-sm">
                {gettext("Save media limits")}
              </.button>
            </.form>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end
end
