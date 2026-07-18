defmodule Goodmao2Web.Helpers do
  @moduledoc """
  App-wide view helpers shared across LiveViews and components.

  Holds the localized label translations for domain enums (roles, species, log
  types) and the human-readable rendering of a structured log entry's payload.
  All user-visible strings go through Gettext.
  """
  use Gettext, backend: Goodmao2Web.Gettext

  ## Enum label translations

  def translate_role("owner"), do: gettext("Owner")
  def translate_role("co_caretaker"), do: gettext("Co-caretaker")
  def translate_role("viewer"), do: gettext("Viewer")
  def translate_role("vet"), do: gettext("Veterinarian")
  def translate_role(other), do: other

  def translate_species("cat"), do: gettext("Cat")
  def translate_species("dog"), do: gettext("Dog")
  def translate_species("other"), do: gettext("Other")
  def translate_species(other), do: other

  def translate_sex("male"), do: gettext("Male")
  def translate_sex("female"), do: gettext("Female")
  def translate_sex("unknown"), do: gettext("Unknown")
  def translate_sex(other), do: other

  def translate_weight_unit("grams"), do: gettext("grams")
  def translate_weight_unit("kilograms"), do: gettext("kilograms")
  def translate_weight_unit("pounds"), do: gettext("pounds")
  def translate_weight_unit(other), do: other

  def translate_lifecycle("active"), do: gettext("Active")
  def translate_lifecycle("passed_away"), do: gettext("Passed away")
  def translate_lifecycle("rehomed"), do: gettext("Rehomed")
  def translate_lifecycle("lost"), do: gettext("Lost")
  def translate_lifecycle("other"), do: gettext("Other")
  def translate_lifecycle(other), do: other

  def translate_visibility("private"), do: gettext("Private")
  def translate_visibility("limited"), do: gettext("Limited")
  def translate_visibility("public"), do: gettext("Public")
  def translate_visibility(other), do: other

  ## Log type labels

  def log_type_label("food"), do: gettext("Food")
  def log_type_label("water"), do: gettext("Water")
  def log_type_label("bathroom"), do: gettext("Bathroom")
  def log_type_label("vomit"), do: gettext("Vomiting")
  def log_type_label("weight"), do: gettext("Weight")
  def log_type_label("energy"), do: gettext("Energy")
  def log_type_label("medication"), do: gettext("Medication")
  def log_type_label("symptom"), do: gettext("Symptom")
  def log_type_label("vet_note"), do: gettext("Vet note")
  def log_type_label("life"), do: gettext("Daily life")
  def log_type_label(other), do: other

  @doc "A heroicon name that visually represents a log type."
  def log_type_icon("food"), do: "hero-cake"
  def log_type_icon("water"), do: "hero-beaker"
  def log_type_icon("bathroom"), do: "hero-funnel"
  def log_type_icon("vomit"), do: "hero-exclamation-triangle"
  def log_type_icon("weight"), do: "hero-scale"
  def log_type_icon("energy"), do: "hero-bolt"
  def log_type_icon("medication"), do: "hero-beaker"
  def log_type_icon("symptom"), do: "hero-heart"
  def log_type_icon("vet_note"), do: "hero-clipboard-document-check"
  def log_type_icon("life"), do: "hero-photo"
  def log_type_icon(_), do: "hero-pencil-square"

  @doc """
  Renders a structured log entry's `data` payload into a short human summary.

  A raw clinical string, localized where the values are enums. Free-text fields
  (names, doses) are shown verbatim.
  """
  def log_summary(%{type: type, data: data}), do: log_summary(type, data || %{})

  def log_summary("food", d) do
    amount = translate_food_amount(d["amount"])
    [amount, d["food_type"], portion(d["portion_grams"])] |> compact_join()
  end

  def log_summary("water", d) do
    amount =
      case d["amount"] do
        "normal" -> gettext("Normal intake")
        "low" -> gettext("Low intake")
        "high" -> gettext("High intake")
        _ -> gettext("Water")
      end

    [amount, ml(d["volume_ml"])] |> compact_join()
  end

  def log_summary("bathroom", d) do
    kind =
      case d["kind"] do
        "urine" -> gettext("Urine")
        "stool" -> gettext("Stool")
        _ -> gettext("Bathroom")
      end

    flags =
      [
        d["consistency"],
        d["has_blood"] == true && gettext("blood"),
        d["straining"] == true && gettext("straining ⚠")
      ]
      |> Enum.filter(& &1)

    [kind | flags] |> compact_join()
  end

  def log_summary("vomit", d) do
    count = d["count"] || 1

    ngettext("%{count} episode", "%{count} episodes", count, count: count)
    |> then(&[&1, d["contents"]])
    |> compact_join()
  end

  def log_summary("weight", d) do
    case d["weight_grams"] do
      nil -> gettext("Weight")
      g -> gettext("%{kg} kg", kg: format_kg(g))
    end
  end

  def log_summary("energy", d) do
    level = d["level"] || "?"
    [gettext("Energy %{level}/5", level: level), d["mood"]] |> compact_join()
  end

  def log_summary("medication", d) do
    [d["medication_name"], d["dose"]] |> compact_join()
  end

  def log_summary("symptom", d) do
    [d["symptom"], severity(d["severity"])] |> compact_join()
  end

  def log_summary("vet_note", d) do
    [d["assessment"], d["recommendation"]] |> compact_join()
  end

  def log_summary("life", _d), do: gettext("Daily life")
  def log_summary(_type, _d), do: ""

  ## Formatting

  @doc "Formats a UTC datetime for display (date + short time)."
  def format_datetime(nil), do: ""

  def format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  @doc "Formats a UTC datetime as a date only."
  def format_date(nil), do: ""
  def format_date(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")
  def format_date(%Date{} = d), do: Calendar.strftime(d, "%Y-%m-%d")

  ## Private

  defp translate_food_amount("full"), do: gettext("Ate fully")
  defp translate_food_amount("partial"), do: gettext("Ate partially")
  defp translate_food_amount("refused"), do: gettext("Refused food")
  defp translate_food_amount(_), do: gettext("Food")

  defp portion(nil), do: nil
  defp portion(g), do: gettext("%{g} g", g: g)

  defp ml(nil), do: nil
  defp ml(v), do: gettext("%{v} ml", v: v)

  defp severity(nil), do: nil
  defp severity(s), do: gettext("severity %{s}/5", s: s)

  defp format_kg(grams) when is_number(grams),
    do: :erlang.float_to_binary(grams / 1000, decimals: 2)

  defp format_kg(other), do: other

  defp compact_join(parts) do
    parts
    |> Enum.filter(&(&1 && &1 != ""))
    |> Enum.join(" · ")
  end
end
