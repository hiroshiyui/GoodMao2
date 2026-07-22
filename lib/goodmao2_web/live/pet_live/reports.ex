defmodule Goodmao2Web.PetLive.Reports do
  @moduledoc """
  Health-summary reports for a pet.

  `:index` lists the pet's reports and (for owners) offers a date-range **Generate** form.
  `:show` renders one frozen report via the shared `report_body/1`, print-friendly, with
  owner-only share-link and delete controls.

  Any effective grant may read reports (so a vet sees them); generating, sharing, and
  deleting require `:manage` (owner) — enforced in `Goodmao2.Reports`.
  """
  use Goodmao2Web, :live_view

  alias Goodmao2.Reports

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_scope.user

    case Goodmao2.Pets.fetch_pet(user, id) do
      {:ok, pet} ->
        {:ok,
         socket
         |> assign(:pet, pet)
         |> assign(:can_manage?, Goodmao2.Pets.can?(pet, user, :manage))
         |> assign(:new_share_url, nil)}

      {:error, :not_found} ->
        {:ok,
         socket |> put_flash(:error, gettext("Pet not found.")) |> push_navigate(to: ~p"/pets")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, gettext("Reports for %{name}", name: socket.assigns.pet.name))
    |> assign(:generate_form, to_form(%{}, as: :report))
    |> assign(
      :reports,
      Reports.list_reports(socket.assigns.current_scope.user, socket.assigns.pet)
    )
  end

  defp apply_action(socket, :show, %{"report_id" => rid} = params) do
    user = socket.assigns.current_scope.user

    case Reports.fetch_report(user, socket.assigns.pet, rid) do
      nil ->
        socket
        |> put_flash(:error, gettext("Report not found."))
        |> push_navigate(to: ~p"/pets/#{socket.assigns.pet.id}/reports")

      report ->
        socket
        |> assign(:page_title, gettext("Health summary"))
        |> assign(:report, report)
        |> assign(:page, parse_page(params["page"]))
        |> assign(:share_form, to_form(%{}, as: :share))
    end
  end

  # A 1-based page number from the query string, defaulting to 1 on anything unparseable.
  defp parse_page(value) do
    case value && Integer.parse(to_string(value)) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  @impl true
  def handle_event("generate", %{"report" => params}, socket) do
    with {:ok, period_start} <- parse_date(params["period_start"]),
         {:ok, period_end} <- parse_date(params["period_end"]),
         {:ok, _report} <-
           Reports.generate_report(socket.assigns.current_scope.user, socket.assigns.pet, %{
             period_start: period_start,
             period_end: period_end
           }) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Report generated."))
       |> assign(
         :reports,
         Reports.list_reports(socket.assigns.current_scope.user, socket.assigns.pet)
       )}
    else
      :invalid_date ->
        {:noreply,
         put_flash(socket, :error, gettext("Please choose a valid start and end date."))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, gettext("You are not allowed to generate reports."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not generate the report. Check the dates."))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user
    report = Reports.fetch_report(user, socket.assigns.pet, id)

    if report do
      case Reports.delete_report(user, socket.assigns.pet, report) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Report deleted."))
           |> push_navigate(to: ~p"/pets/#{socket.assigns.pet.id}/reports")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete that report."))}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Report not found."))}
    end
  end

  def handle_event("share", %{"share" => %{"expires_at" => expires_at}}, socket) do
    user = socket.assigns.current_scope.user

    with {:ok, dt} <- parse_datetime(expires_at, socket.assigns.timezone),
         {:ok, {report, token}} <-
           Reports.create_share_token(user, socket.assigns.pet, socket.assigns.report, dt) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Share link created. Copy it now — it is shown only once."))
       |> assign(:report, report)
       |> assign(:new_share_url, url(~p"/reports/shared/#{token}"))}
    else
      :invalid_date ->
        {:noreply,
         put_flash(socket, :error, gettext("Please choose when the link should expire."))}

      {:error, :expiry_in_past} ->
        {:noreply, put_flash(socket, :error, gettext("The expiry must be in the future."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not create a share link."))}
    end
  end

  def handle_event("revoke_share", _params, socket) do
    user = socket.assigns.current_scope.user

    case Reports.revoke_share_token(user, socket.assigns.pet, socket.assigns.report) do
      {:ok, report} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Share link revoked."))
         |> assign(:report, report)
         |> assign(:new_share_url, nil)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not revoke the link."))}
    end
  end

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> {:ok, date}
      _ -> :invalid_date
    end
  end

  defp parse_date(_), do: :invalid_date

  # `datetime-local` inputs submit "YYYY-MM-DDTHH:MM" with no zone; interpret the wall-clock in
  # the viewer's timezone and store UTC (ADR-0018).
  defp parse_datetime(str, tz) when is_binary(str) and str != "" do
    case Goodmao2.Timezone.local_naive_to_utc(str, tz) do
      {:ok, dt} -> {:ok, dt}
      :error -> :invalid_date
    end
  end

  defp parse_datetime(_, _tz), do: :invalid_date

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
      current_user_avatar={@current_user_avatar}
    >
      <section id="reports-section" aria-labelledby="reports-heading" class="mx-auto max-w-xl">
        <div class="flex items-center gap-2">
          <.link
            navigate={~p"/pets/#{@pet.id}"}
            id="reports-back"
            class="btn btn-ghost btn-sm btn-circle"
            aria-label={gettext("Back")}
          >
            <.icon name="hero-arrow-left" class="size-4" />
          </.link>
          <h1 id="reports-heading" class="text-2xl font-semibold">
            {gettext("Reports for %{name}", name: @pet.name)}
          </h1>
        </div>

        <.form
          :if={@can_manage?}
          for={@generate_form}
          id="generate-report-form"
          phx-submit="generate"
          class="card card-border bg-base-100 mt-6"
        >
          <div class="card-body space-y-3 p-4">
            <h2 class="text-lg font-semibold">{gettext("Generate a report")}</h2>
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@generate_form[:period_start]}
                type="date"
                label={gettext("From")}
                required
              />
              <.input field={@generate_form[:period_end]} type="date" label={gettext("To")} required />
            </div>
            <p class="text-base-content/60 text-xs">
              {gettext(
                "A report freezes the timeline for this range. Private entries are never included."
              )}
            </p>
            <.button type="submit" id="generate-report-submit" class="btn btn-primary w-fit">
              {gettext("Generate")}
            </.button>
          </div>
        </.form>

        <h2 id="reports-list-heading" class="mt-8 text-lg font-semibold">
          {gettext("Generated reports")}
        </h2>
        <ul id="reports" class="mt-3 space-y-2">
          <li :if={@reports == []} id="reports-empty" class="text-base-content/60 py-4 text-center">
            {gettext("No reports yet.")}
          </li>
          <li
            :for={report <- @reports}
            id={"report-#{report.id}"}
            class="report-row card card-border bg-base-100"
          >
            <div class="card-body flex-row items-center justify-between gap-3 p-3">
              <div class="min-w-0">
                <p class="report-row-period font-medium">
                  {format_date(report.period_start)} – {format_date(report.period_end)}
                </p>
                <p class="report-row-meta text-base-content/60 text-sm">
                  {gettext("Generated %{t}", t: format_datetime(report.inserted_at))}
                  <span :if={report.share_expires_at} class="badge badge-ghost badge-sm ml-1">
                    {gettext("Shared")}
                  </span>
                </p>
              </div>
              <.link
                navigate={~p"/pets/#{@pet.id}/reports/#{report.id}"}
                id={"report-view-#{report.id}"}
                class="btn btn-ghost btn-sm"
              >
                {gettext("View")}
              </.link>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end

  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      unread_notifications={@unread_notifications}
      unread_messages={@unread_messages}
      current_user_avatar={@current_user_avatar}
    >
      <section id="report-show" aria-labelledby="report-show-heading" class="mx-auto max-w-2xl">
        <div class="flex items-center justify-between gap-2 print:hidden">
          <div class="flex items-center gap-2">
            <.link
              navigate={~p"/pets/#{@pet.id}/reports"}
              id="report-back"
              class="btn btn-ghost btn-sm btn-circle"
              aria-label={gettext("Back")}
            >
              <.icon name="hero-arrow-left" class="size-4" />
            </.link>
            <h1 id="report-show-heading" class="text-2xl font-semibold">
              {gettext("Health summary")}
            </h1>
          </div>
          <button type="button" id="report-print" phx-hook="Print" class="btn btn-soft btn-sm">
            <.icon name="hero-printer" class="size-4" /> {gettext("Print")}
          </button>
        </div>

        <div class="mt-6">
          <.report_body
            content={@report.content}
            period_start={@report.period_start}
            period_end={@report.period_end}
            page={@page}
            base_path={~p"/pets/#{@pet.id}/reports/#{@report.id}"}
          />
        </div>

        <div
          :if={@can_manage?}
          id="report-share"
          class="card card-border bg-base-100 mt-8 print:hidden"
        >
          <div class="card-body space-y-3 p-4">
            <h2 class="text-lg font-semibold">{gettext("Share with a veterinarian")}</h2>

            <div :if={@new_share_url} id="report-share-url" class="alert alert-info text-sm break-all">
              {@new_share_url}
            </div>

            <div :if={@report.share_expires_at} id="report-share-active" class="text-sm">
              <p class="text-base-content/70">
                {gettext("A share link is active until %{t}.",
                  t: format_datetime(@report.share_expires_at)
                )}
              </p>
              <button
                type="button"
                id="report-share-revoke"
                phx-click="revoke_share"
                data-confirm={gettext("Revoke the share link?")}
                class="btn btn-ghost btn-sm mt-2"
              >
                {gettext("Revoke link")}
              </button>
            </div>

            <.form
              :if={is_nil(@report.share_expires_at)}
              for={@share_form}
              id="report-share-form"
              phx-submit="share"
            >
              <.input
                field={@share_form[:expires_at]}
                type="datetime-local"
                label={gettext("Link expires")}
                required
              />
              <p class="text-base-content/60 mt-1 text-xs">
                {gettext("Anyone with the link can read this report until it expires.")}
              </p>
              <.button type="submit" id="report-share-submit" class="btn btn-primary btn-sm mt-2">
                {gettext("Create share link")}
              </.button>
            </.form>
          </div>
        </div>

        <div :if={@can_manage?} class="mt-6 print:hidden">
          <button
            type="button"
            id="report-delete"
            phx-click="delete"
            phx-value-id={@report.id}
            data-confirm={gettext("Delete this report?")}
            class="btn btn-ghost btn-sm text-error"
          >
            {gettext("Delete report")}
          </button>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
