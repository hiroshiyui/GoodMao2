defmodule Goodmao2Web.LogFields do
  @moduledoc """
  The per-type structured input fields for a log entry, shared by QuickLog (`PetLive.Show`)
  and the entry editor (`PetLive.LogEntry`).

  `log_fields/1` dispatches on the log `type` to the right set of `<.input>` controls, bound
  to the given `form`. Keeping it here means the new-entry and edit-entry forms can never
  drift apart.
  """
  use Phoenix.Component
  use Gettext, backend: Goodmao2Web.Gettext

  import Goodmao2Web.CoreComponents

  attr :type, :string, required: true
  attr :form, :map, required: true

  def log_fields(%{type: "food"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-3">
      <.input
        field={@form[:amount]}
        type="select"
        label={gettext("Amount")}
        options={[
          {gettext("Ate fully"), "full"},
          {gettext("Ate partially"), "partial"},
          {gettext("Refused"), "refused"}
        ]}
      />
      <.input field={@form[:food_type]} type="text" label={gettext("Food")} />
      <.input field={@form[:portion_grams]} type="number" label={gettext("Portion (g)")} min="0" />
    </div>
    """
  end

  def log_fields(%{type: "water"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input
        field={@form[:amount]}
        type="select"
        label={gettext("Intake")}
        options={[{gettext("Normal"), "normal"}, {gettext("Low"), "low"}, {gettext("High"), "high"}]}
      />
      <.input field={@form[:volume_ml]} type="number" label={gettext("Volume (ml)")} min="0" />
    </div>
    """
  end

  def log_fields(%{type: "bathroom"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input
        field={@form[:kind]}
        type="select"
        label={gettext("Kind")}
        options={[{gettext("Urine"), "urine"}, {gettext("Stool"), "stool"}]}
      />
      <.input field={@form[:consistency]} type="text" label={gettext("Consistency")} />
    </div>
    <div class="flex flex-wrap gap-4">
      <.input field={@form[:has_blood]} type="checkbox" label={gettext("Blood present")} />
      <.input
        field={@form[:straining]}
        type="checkbox"
        label={gettext("Straining (⚠ cat emergency)")}
      />
    </div>
    """
  end

  def log_fields(%{type: "vomit"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input
        field={@form[:count]}
        type="number"
        label={gettext("Episodes")}
        min="1"
        value={@form[:count].value || "1"}
      />
      <.input field={@form[:contents]} type="text" label={gettext("Contents")} />
    </div>
    """
  end

  def log_fields(%{type: "weight"} = assigns) do
    ~H"""
    <.input
      field={@form[:weight_grams]}
      type="number"
      label={gettext("Weight (grams)")}
      min="0"
      required
    />
    """
  end

  def log_fields(%{type: "energy"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input
        field={@form[:level]}
        type="select"
        label={gettext("Energy level")}
        options={Enum.map(1..5, &{"#{&1}", "#{&1}"})}
      />
      <.input field={@form[:mood]} type="text" label={gettext("Mood")} />
    </div>
    """
  end

  def log_fields(%{type: "medication"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input field={@form[:medication_name]} type="text" label={gettext("Medication")} required />
      <.input field={@form[:dose]} type="text" label={gettext("Dose")} required />
    </div>
    """
  end

  def log_fields(%{type: "symptom"} = assigns) do
    ~H"""
    <div class="grid gap-3 sm:grid-cols-2">
      <.input field={@form[:symptom]} type="text" label={gettext("Symptom")} required />
      <.input
        field={@form[:severity]}
        type="select"
        label={gettext("Severity")}
        options={Enum.map(1..5, &{"#{&1}", "#{&1}"})}
      />
    </div>
    """
  end

  def log_fields(%{type: "vet_note"} = assigns) do
    ~H"""
    <div class="space-y-3">
      <.input
        field={@form[:assessment]}
        type="textarea"
        label={gettext("Assessment")}
        rows="2"
        required
      />
      <.input
        field={@form[:recommendation]}
        type="textarea"
        label={gettext("Recommendation")}
        rows="2"
      />
    </div>
    """
  end

  def log_fields(%{type: "life"} = assigns) do
    ~H"""
    <.input
      field={@form[:note]}
      type="textarea"
      label={gettext("What happened?")}
      rows="3"
      required
    />
    """
  end

  def log_fields(assigns), do: ~H""
end
