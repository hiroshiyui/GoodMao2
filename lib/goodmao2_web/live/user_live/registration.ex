defmodule Goodmao2Web.UserLive.Registration do
  use Goodmao2Web, :live_view

  alias Goodmao2.Accounts
  alias Goodmao2.Accounts.RegistrationRateLimiter
  alias Goodmao2.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            {gettext("Register for an account")}
            <:subtitle>
              {gettext("Already registered?")}
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                {gettext("Log in")}
              </.link>
              {gettext("to your account now.")}
            </:subtitle>
          </.header>
        </div>

        <.form for={@form} id="registration_form" phx-submit="save" phx-change="validate">
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Email")}
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />

          <.button phx-disable-with={gettext("Creating account...")} class="btn btn-primary w-full">
            {gettext("Create an account")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: Goodmao2Web.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok,
     socket
     |> assign(:page_title, gettext("Register for an account"))
     |> assign_form(changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => %{"email" => email} = user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:noreply, deliver_and_ack(socket, email, user)}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Existence-hidden: a duplicate email must respond exactly like a fresh signup, or the
        # form becomes a membership oracle. If the address already has an account, send THAT
        # account a login link so its owner still gets in; otherwise the neutral ack is a
        # harmless no-op. Every other validation error (format, length, blank) is safe to show.
        if email_taken?(changeset),
          do: {:noreply, deliver_and_ack(socket, email, Accounts.get_user_by_email(email))},
          else: {:noreply, assign_form(socket, changeset)}

      {:error, :not_site_owner} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Registration is restricted to the site owner for the first account.")
         )}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # Send the magic link (rate-limited per address) and show the same neutral confirmation
  # regardless of whether an account was created, already existed, or the send was throttled —
  # so the response never reveals which. `user` is nil only if a taken email vanished between
  # the insert attempt and the lookup, in which case there is simply nothing to send.
  defp deliver_and_ack(socket, email, user) do
    if user && RegistrationRateLimiter.check(email) == :ok do
      {:ok, _} = Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
    end

    socket
    |> put_flash(
      :info,
      gettext("An email was sent to %{email}, please access it to confirm your account.",
        email: email
      )
    )
    |> push_navigate(to: ~p"/users/log-in")
  end

  # True when the changeset failed solely because the email is already registered (from
  # `unsafe_validate_unique` pre-insert, or the unique constraint on a raced insert).
  defp email_taken?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:email, {_msg, opts}} ->
        opts[:validation] == :unsafe_unique or opts[:constraint] == :unique

      _ ->
        false
    end)
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
