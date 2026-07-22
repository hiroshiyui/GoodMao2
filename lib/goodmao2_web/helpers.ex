defmodule Goodmao2Web.Helpers do
  @moduledoc """
  App-wide view helpers shared across LiveViews and components.

  Holds the localized label translations for domain enums (roles, species, log
  types) and the human-readable rendering of a structured log entry's payload.
  All user-visible strings go through Gettext.
  """
  use Gettext, backend: Goodmao2Web.Gettext
  use Goodmao2Web, :verified_routes

  @doc """
  The brand wordmark, rendered through Gettext so it varies per locale (ADR-0002):
  `GoodMao` (en) / `顧毛` (zh_TW) / `グッドマオ` (ja_JP). Never hard-code the wordmark —
  call this so every surface stays consistent and adding a locale needs no code change.
  """
  def brand_name, do: gettext("GoodMao")

  ## Enum label translations

  def translate_role("owner"), do: gettext("Owner")
  def translate_role("co_caretaker"), do: gettext("Co-caretaker")
  def translate_role("viewer"), do: gettext("Viewer")
  def translate_role("vet"), do: gettext("Veterinarian")
  def translate_role(other), do: other

  def translate_species("cat"), do: gettext("Cat")
  def translate_species("dog"), do: gettext("Dog")
  def translate_species("rabbit"), do: gettext("Rabbit")
  def translate_species("bird"), do: gettext("Bird")
  def translate_species("hamster"), do: gettext("Hamster")
  def translate_species("reptile"), do: gettext("Reptile")
  def translate_species("fish"), do: gettext("Fish")
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

  @doc """
  A deliberately gentle glyph for a pet's ended lifecycle status. A pet's passing is a
  tender moment, so `passed_away` is a soft heart — never anything morbid or alarming
  (ADR-0003, the "be gracious to people" principle).
  """
  def lifecycle_icon("passed_away"), do: "hero-heart"
  def lifecycle_icon("rehomed"), do: "hero-home"
  def lifecycle_icon("lost"), do: "hero-question-mark-circle"
  def lifecycle_icon(_), do: "hero-bookmark"

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

  @doc "Accessible alt text for a life-log image — its caption, or a localized default."
  def media_alt(%{caption: caption}) when is_binary(caption) and caption != "", do: caption
  def media_alt(_asset), do: gettext("Life log photo")

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

  ## Notifications (ADR-0011): copy is rendered from `type` + payload, never stored

  @doc "A short, localized title for a notification (its heading in the feed)."
  def notification_title(%{type: type, payload: payload}), do: notification_title(type, payload)

  def notification_title("access_granted", _p), do: gettext("Access granted")
  def notification_title("access_revoked", _p), do: gettext("Access removed")
  def notification_title("log_added", _p), do: gettext("New log entry")
  # An announcement's title is admin-authored free text, shown verbatim.
  def notification_title("announcement", p), do: p["title"] || gettext("Announcement")
  def notification_title("medication_due", _p), do: gettext("Medication due")
  def notification_title("media_failed", _p), do: gettext("Upload couldn't be processed")
  def notification_title("avatar_failed", _p), do: gettext("Profile photo couldn't be processed")
  def notification_title(_type, _p), do: gettext("Notification")

  @doc "A localized one-line summary of a notification, rendered from its payload."
  def notification_summary(%{type: type, payload: payload}),
    do: notification_summary(type, payload)

  def notification_summary("access_granted", p) do
    gettext("%{actor} gave you %{role} access to %{pet}.",
      actor: actor_name(p["actor"]),
      role: translate_role(p["role"]),
      pet: p["pet_name"]
    )
  end

  def notification_summary("access_revoked", p) do
    gettext("%{actor} removed your access to %{pet}.",
      actor: actor_name(p["actor"]),
      pet: p["pet_name"]
    )
  end

  def notification_summary("log_added", p) do
    gettext("A new %{type} entry was recorded for %{pet}.",
      type: log_type_label(p["log_type"]),
      pet: p["pet_name"]
    )
  end

  def notification_summary("medication_due", p) do
    gettext("%{medication} (%{dose}) is due for %{pet}.",
      medication: p["medication_name"],
      dose: p["dose"],
      pet: p["pet_name"]
    )
  end

  # An announcement body is admin-authored free text, shown verbatim.
  def notification_summary("announcement", p), do: p["body"]

  def notification_summary("media_failed", _p),
    do:
      gettext(
        "A photo or video you uploaded couldn't be processed — check the format and try again."
      )

  def notification_summary("avatar_failed", _p),
    do:
      gettext(
        "The profile photo you uploaded couldn't be processed — check the format and try again."
      )

  def notification_summary(_type, _p), do: nil

  @doc "A heroicon name for a notification type."
  def notification_icon("access_granted"), do: "hero-user-plus"
  def notification_icon("access_revoked"), do: "hero-user-minus"
  def notification_icon("log_added"), do: "hero-pencil-square"
  def notification_icon("announcement"), do: "hero-megaphone"
  def notification_icon("medication_due"), do: "hero-beaker"
  def notification_icon("media_failed"), do: "hero-exclamation-triangle"
  def notification_icon("avatar_failed"), do: "hero-exclamation-triangle"
  def notification_icon(_type), do: "hero-bell"

  @doc """
  The in-app path a notification links to, or `nil` when it isn't navigable.

  A revoked-access notification points at the pet list (the caller no longer has a grant),
  a new-log notification at that entry, and other pet events at the pet page.
  """
  def notification_path(%{type: "log_added", payload: %{"pet_id" => pet_id, "entry_id" => id}}),
    do: ~p"/pets/#{pet_id}/logs/#{id}"

  def notification_path(%{type: "access_granted", payload: %{"pet_id" => pet_id}}),
    do: ~p"/pets/#{pet_id}"

  def notification_path(%{type: "access_revoked"}), do: ~p"/pets"

  def notification_path(%{type: "medication_due", payload: %{"pet_id" => pet_id}}),
    do: ~p"/pets/#{pet_id}/medications"

  def notification_path(%{
        type: "media_failed",
        payload: %{"pet_id" => pet_id, "log_entry_id" => id}
      }),
      do: ~p"/pets/#{pet_id}/logs/#{id}"

  def notification_path(_notification), do: nil

  @doc """
  Builds the Web Push payload for a new mailbox message (ADR-0011 Stage 2).

  Mailbox messages create no bell row, so this renders push copy directly from the sender
  and body: the sender's public label as the title (like a chat app) and a short preview as
  the body, deep-linking to the thread. Rendered in the default locale (the dispatch worker
  has no per-request locale). `sender` may be `nil` (a deleted account).
  """
  def message_push_payload(sender, body, conversation_id) do
    %{
      title: message_push_title(sender),
      body: message_push_preview(body),
      url: url(~p"/messages/#{conversation_id}"),
      type: "message",
      icon: nil
    }
  end

  defp message_push_title(%{handle: h}) when is_binary(h) and h != "", do: "@" <> h
  defp message_push_title(%{display_name: n}) when is_binary(n) and n != "", do: n
  defp message_push_title(_), do: gettext("New message")

  defp message_push_preview(body) do
    trimmed = String.trim(body || "")
    if String.length(trimmed) > 140, do: String.slice(trimmed, 0, 140) <> "…", else: trimmed
  end

  # A non-leaking actor label, or a gentle generic when the actor had no public name.
  defp actor_name(name) when is_binary(name) and name != "", do: name
  defp actor_name(_), do: gettext("Someone")

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

  @doc """
  A localized one-line summary, weight-unit-aware. For `weight` entries the value renders in the
  pet's `unit`; every other type ignores `unit` and defers to `log_summary/2`. Must precede the
  `log_summary(_type, _d)` catch-all below, or that would shadow this arity-2 map clause.
  """
  def log_summary(%{type: type, data: data}, unit) when is_binary(unit),
    do: log_summary(type, data || %{}, unit)

  def log_summary(_type, _d), do: ""

  def log_summary("weight", d, unit) do
    case d["weight_grams"] do
      nil -> gettext("Weight")
      g -> format_weight(g, unit)
    end
  end

  def log_summary(type, d, _unit), do: log_summary(type, d)

  ## Formatting
  #
  # Datetimes are stored UTC (ADR-0018); these helpers shift into the viewer's active timezone
  # (`Goodmao2.Timezone.current/0`, set per request/socket) before formatting. The `/2` arities
  # take an explicit zone for callers that must override the process default. A `%Date{}` is
  # zoneless and formatted as-is.

  @doc "Formats a UTC datetime for display (date + short time) in the active timezone."
  def format_datetime(dt), do: format_datetime(dt, Goodmao2.Timezone.current())

  @doc "Formats a UTC datetime for display (date + short time) in `tz`."
  def format_datetime(nil, _tz), do: ""

  def format_datetime(%DateTime{} = dt, tz) do
    dt |> Goodmao2.Timezone.to_local(tz) |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  @doc "Formats a UTC datetime (or a Date) as a date only, in the active timezone."
  def format_date(dt), do: format_date(dt, Goodmao2.Timezone.current())

  @doc "Formats a UTC datetime (or a Date) as a date only, in `tz`."
  def format_date(nil, _tz), do: ""
  def format_date(%Date{} = d, _tz), do: Calendar.strftime(d, "%Y-%m-%d")

  def format_date(%DateTime{} = dt, tz) do
    dt |> Goodmao2.Timezone.to_local(tz) |> Calendar.strftime("%Y-%m-%d")
  end

  ## Clinical flags

  @doc """
  The clinical concern "chips" an entry should surface, most-severe first (or `[]`).

  Each flag is a `%{level: :urgent | :watch, icon: <heroicon>, label: <localized>}`. These
  are the high-signal cues worth scanning for — feline urinary blood/straining, not eating,
  repeated vomiting, a severe symptom — each meant to be carried by icon **and** text **and**
  shape, never colour alone (WCAG 1.4.1).

  This is the **single source of truth** for clinical urgency: `clinical_level/1` (the
  calendar day-cell tint) is derived from it, so the timeline chips and the calendar can
  never disagree.
  """
  def clinical_flags(%{type: type, data: data}), do: clinical_flags(type, data || %{})
  def clinical_flags(_), do: []

  def clinical_flags("bathroom", data) when is_map(data) do
    [
      data["has_blood"] == true &&
        %{level: :urgent, icon: "hero-exclamation-triangle", label: gettext("Blood")},
      data["straining"] == true &&
        %{level: :urgent, icon: "hero-exclamation-triangle", label: gettext("Straining")}
    ]
    |> Enum.filter(& &1)
  end

  def clinical_flags("food", %{"amount" => "refused"}),
    do: [%{level: :watch, icon: "hero-exclamation-circle", label: gettext("Not eating")}]

  def clinical_flags("vomit", data) when is_map(data) do
    # A single episode is common; repeated vomiting is the red flag.
    if is_number(data["count"]) and data["count"] >= 3 do
      [%{level: :urgent, icon: "hero-exclamation-triangle", label: gettext("Repeated vomiting")}]
    else
      [%{level: :watch, icon: "hero-exclamation-circle", label: gettext("Vomiting")}]
    end
  end

  def clinical_flags("symptom", data) when is_map(data) do
    if is_number(data["severity"]) and data["severity"] >= 4 do
      [%{level: :urgent, icon: "hero-exclamation-triangle", label: gettext("Severe symptom")}]
    else
      []
    end
  end

  def clinical_flags(_type, _data), do: []

  ## Calendar (month-grid timeline view)

  @doc """
  The single clinical urgency level for an entry (`:urgent` > `:watch` > `nil`).

  The most severe of the entry's `clinical_flags/1`. The calendar day cell pairs this with
  an icon, so the tint is never the sole carrier of meaning.
  """
  def clinical_level(entry) do
    entry
    |> clinical_flags()
    |> Enum.reduce(nil, fn %{level: level}, acc -> escalate(acc, level) end)
  end

  @doc "The more severe of two clinical levels (`:urgent` > `:watch` > `nil`)."
  def escalate(:urgent, _), do: :urgent
  def escalate(_, :urgent), do: :urgent
  def escalate(:watch, _), do: :watch
  def escalate(_, :watch), do: :watch
  def escalate(_, _), do: nil

  @doc "Localized long month label for a `Date`, e.g. \"July 2026\" / \"2026年7月\"."
  def month_label(%Date{year: year, month: month}) do
    gettext("%{month} %{year}", month: month_name(month), year: year)
  end

  @doc "Localized full-date label for a `Date`, e.g. \"July 18, 2026\" / \"2026年7月18日\"."
  def day_label(%Date{year: year, month: month, day: day}) do
    gettext("%{month} %{day}, %{year}", month: month_name(month), day: day, year: year)
  end

  def month_name(1), do: gettext("January")
  def month_name(2), do: gettext("February")
  def month_name(3), do: gettext("March")
  def month_name(4), do: gettext("April")
  def month_name(5), do: gettext("May")
  def month_name(6), do: gettext("June")
  def month_name(7), do: gettext("July")
  def month_name(8), do: gettext("August")
  def month_name(9), do: gettext("September")
  def month_name(10), do: gettext("October")
  def month_name(11), do: gettext("November")
  def month_name(12), do: gettext("December")

  @doc "Short weekday name, Sunday-first (`0` = Sunday .. `6` = Saturday)."
  def weekday_short(0), do: gettext("Sun")
  def weekday_short(1), do: gettext("Mon")
  def weekday_short(2), do: gettext("Tue")
  def weekday_short(3), do: gettext("Wed")
  def weekday_short(4), do: gettext("Thu")
  def weekday_short(5), do: gettext("Fri")
  def weekday_short(6), do: gettext("Sat")

  @doc "Full weekday name (the accessible expansion of `weekday_short/1`), Sunday-first."
  def weekday_long(0), do: gettext("Sunday")
  def weekday_long(1), do: gettext("Monday")
  def weekday_long(2), do: gettext("Tuesday")
  def weekday_long(3), do: gettext("Wednesday")
  def weekday_long(4), do: gettext("Thursday")
  def weekday_long(5), do: gettext("Friday")
  def weekday_long(6), do: gettext("Saturday")

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

  @doc "Formats a weight in grams as a two-decimal kilogram string (`4200` → `\"4.20\"`)."
  def format_kg(grams) when is_number(grams),
    do: :erlang.float_to_binary(grams / 1000, decimals: 2)

  def format_kg(other), do: other

  # Weight is always stored canonically as grams (`data["weight_grams"]`); these convert only at
  # the display/input edges so a pet's `weight_unit` (grams/kilograms/pounds) is honored
  # (roadmap §8). `@grams_per_pound` is the exact avoirdupois definition.
  @grams_per_pound 453.59237

  @doc "The numeric weight in the pet's `unit`, from a grams value (kg/lb are floats)."
  def weight_from_grams(grams, "grams") when is_number(grams), do: round(grams)
  def weight_from_grams(grams, "pounds") when is_number(grams), do: grams / @grams_per_pound
  def weight_from_grams(grams, _kilograms) when is_number(grams), do: grams / 1000
  def weight_from_grams(other, _unit), do: other

  @doc "Converts an entered weight (number or numeric string) in `unit` to integer grams, or nil."
  def weight_to_grams(value, unit) do
    case to_number(value) do
      nil ->
        nil

      n ->
        grams =
          case unit do
            "grams" -> n
            "pounds" -> n * @grams_per_pound
            _kilograms -> n * 1000
          end

        round(grams)
    end
  end

  @doc "A localized weight for display, in the pet's `unit` (`4200, \"pounds\"` → `\"9.26 lb\"`)."
  def format_weight(grams, "grams") when is_number(grams), do: gettext("%{v} g", v: round(grams))

  def format_weight(grams, "pounds") when is_number(grams),
    do: gettext("%{v} lb", v: two_decimals(grams / @grams_per_pound))

  def format_weight(grams, _kilograms) when is_number(grams),
    do: gettext("%{v} kg", v: two_decimals(grams / 1000))

  def format_weight(other, _unit), do: other

  @doc "The prefill string for a weight input in the pet's `unit`, from a grams value."
  def weight_input_value(grams, "grams") when is_number(grams),
    do: Integer.to_string(round(grams))

  def weight_input_value(grams, unit) when is_number(grams),
    do: two_decimals(weight_from_grams(grams, unit))

  def weight_input_value(_grams, _unit), do: ""

  defp two_decimals(x), do: :erlang.float_to_binary(x / 1, decimals: 2)

  defp to_number(n) when is_number(n), do: n

  defp to_number(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp to_number(_), do: nil

  defp compact_join(parts) do
    parts
    |> Enum.filter(&(&1 && &1 != ""))
    |> Enum.join(" · ")
  end
end
