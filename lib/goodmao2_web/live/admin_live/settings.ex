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

  alias Goodmao2.Notifications.WebPush
  alias Goodmao2.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("System settings"))
     |> load_vapid()}
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

  defp load_vapid(socket) do
    socket
    |> assign(:vapid_public_key, WebPush.public_key())
    |> assign(:vapid_configured, WebPush.vapid_configured?())
    |> assign(:subject_form, to_form(%{"subject" => WebPush.subject()}, as: :vapid))
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
      </section>
    </Layouts.app>
    """
  end
end
