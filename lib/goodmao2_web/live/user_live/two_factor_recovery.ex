defmodule Goodmao2Web.UserLive.TwoFactorRecovery do
  @moduledoc """
  Recovery-code entry for the second-factor challenge (ADR-0013) — the fallback when a
  user has lost access to their authenticator. Submits a native form POST to
  `Goodmao2Web.UserTwoFactorController.recovery/2`, which consumes the single-use code.
  """
  use Goodmao2Web, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4" id="two-factor-recovery">
        <div class="text-center">
          <.header>
            {gettext("Use a recovery code")}
            <:subtitle>
              {gettext(
                "Enter one of the recovery codes you saved when you set up two-step verification."
              )}
            </:subtitle>
          </.header>
        </div>

        <.form
          for={@recovery_form}
          id="recovery_challenge_form"
          action={~p"/users/two-factor/recovery"}
          method="post"
        >
          <.input
            field={@recovery_form[:recovery_code]}
            type="text"
            label={gettext("Recovery code")}
            autocomplete="one-time-code"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.button class="btn btn-primary w-full" id="recovery-challenge-submit">
            {gettext("Verify")}
          </.button>
        </.form>

        <div class="text-center text-sm">
          <.link navigate={~p"/users/two-factor"} id="back-to-challenge" class="link link-primary">
            {gettext("← Back")}
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, gettext("Use a recovery code"))
      |> assign(:recovery_form, to_form(%{"recovery_code" => ""}, as: "user"))

    {:ok, socket}
  end
end
