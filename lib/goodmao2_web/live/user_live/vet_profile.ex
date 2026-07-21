defmodule Goodmao2Web.UserLive.VetProfile do
  @moduledoc """
  Self-service page for a user to submit or re-submit their veterinarian credentials.

  A submission (or edit) always returns the profile to `pending`; an administrator
  reviews it on the `/admin` page. Only a **verified** profile unlocks the per-pet
  `vet` role (enforced in `Goodmao2.Pets`).
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.VetProfile

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    profile = Accounts.get_vet_profile(user) || %VetProfile{}

    {:ok,
     socket
     |> assign(:page_title, gettext("Veterinarian credentials"))
     |> assign(:profile, profile)
     |> assign(:form, to_form(Accounts.change_vet_profile(profile)))}
  end

  @impl true
  def handle_event("validate", %{"vet_profile" => params}, socket) do
    changeset =
      socket.assigns.profile
      |> Accounts.change_vet_profile(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("submit", %{"vet_profile" => params}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.submit_vet_profile(user, params) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Credentials submitted for review."))
         |> assign(:profile, profile)
         |> assign(:form, to_form(Accounts.change_vet_profile(profile)))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
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
      <section id="vet-profile-section" aria-labelledby="vet-profile-heading" class="mx-auto max-w-xl">
        <.header>
          {gettext("Veterinarian credentials")}
          <:subtitle>
            {gettext("Verified professionals can be given read access and author vet notes.")}
          </:subtitle>
        </.header>

        <div :if={@profile.id} id="vet-profile-status" class="mt-4">
          <span class={["badge", status_badge_class(@profile.verification_status)]}>
            {verification_label(@profile.verification_status)}
          </span>
          <p
            :if={@profile.verification_status == "rejected"}
            class="text-base-content/60 mt-2 text-sm"
          >
            {gettext("Your last submission was not accepted. You may correct and resubmit it.")}
          </p>
        </div>

        <.form
          for={@form}
          id="vet-profile-form"
          phx-change="validate"
          phx-submit="submit"
          class="mt-6"
        >
          <.input
            field={@form[:license_number]}
            type="text"
            label={gettext("License number")}
            required
          />
          <.input
            field={@form[:licensing_body]}
            type="text"
            label={gettext("Licensing body")}
            required
          />
          <.input field={@form[:region]} type="text" label={gettext("Region / country")} required />
          <.input field={@form[:clinic_name]} type="text" label={gettext("Clinic name")} required />
          <.input field={@form[:specialty]} type="text" label={gettext("Specialty (optional)")} />

          <.button variant="primary" id="vet-profile-submit" phx-disable-with={gettext("Saving...")}>
            {if @profile.id, do: gettext("Resubmit for review"), else: gettext("Submit for review")}
          </.button>
        </.form>

        <div class="mt-8 text-center">
          <.link navigate={~p"/users/settings"} class="text-base-content/60 text-sm">
            {gettext("Back to account settings")}
          </.link>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp verification_label("pending"), do: gettext("Pending review")
  defp verification_label("verified"), do: gettext("Verified")
  defp verification_label("rejected"), do: gettext("Not accepted")

  defp status_badge_class("pending"), do: "badge-warning"
  defp status_badge_class("verified"), do: "badge-success"
  defp status_badge_class("rejected"), do: "badge-error"
end
