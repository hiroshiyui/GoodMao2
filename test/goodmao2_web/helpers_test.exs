defmodule Goodmao2Web.HelpersTest do
  use ExUnit.Case, async: true

  import Goodmao2Web.Helpers
  alias Goodmao2.Timezone

  describe "weight formatters (unit-aware)" do
    test "format_weight/2 renders in the pet's unit" do
      assert format_weight(4200, "kilograms") == "4.20 kg"
      assert format_weight(4200, "grams") == "4200 g"
      # 4536 g ≈ 10.00 lb (avoirdupois).
      assert format_weight(4536, "pounds") == "10.00 lb"
    end

    test "weight_to_grams/2 converts entered values to canonical grams" do
      assert weight_to_grams("4.2", "kilograms") == 4200
      assert weight_to_grams("4200", "grams") == 4200
      assert weight_to_grams("10", "pounds") == 4536
      assert weight_to_grams("", "kilograms") == nil
      assert weight_to_grams("not-a-number", "grams") == nil
    end

    test "weight_input_value/2 round-trips a stored grams value back to the unit field" do
      assert weight_input_value(4200, "kilograms") == "4.20"
      assert weight_input_value(4200, "grams") == "4200"
      assert weight_input_value(4536, "pounds") == "10.00"
    end
  end

  describe "enum labels" do
    alias Goodmao2.Logs.LogEntry

    # Every schema enum a page renders, with the helper that labels it. A value added
    # to a schema without a label clause falls through to the helper's catch-all and
    # renders the raw identifier (`co_caretaker`, `passed_away`) in every locale.
    defp enums do
      schema = [
        {"PetAccess role", Goodmao2.Pets.PetAccess.roles(), &translate_role/1},
        {"Pet species", Goodmao2.Pets.Pet.species(), &translate_species/1},
        {"Pet sex", Goodmao2.Pets.Pet.sexes(), &translate_sex/1},
        {"Pet weight unit", Goodmao2.Pets.Pet.weight_units(), &translate_weight_unit/1},
        {"Pet lifecycle status", Goodmao2.Pets.Pet.lifecycle_statuses(), &translate_lifecycle/1},
        {"LogEntry visibility", LogEntry.visibilities(), &translate_visibility/1},
        {"LogEntry type", LogEntry.types(), &log_type_label/1},
        {"Dose status", Goodmao2.Medications.Dose.statuses(), &translate_dose_status/1},
        {"VetProfile status", Goodmao2.Accounts.VetProfile.statuses(), &translate_vet_status/1},
        {"Notification type", Goodmao2.Notifications.Notification.types(),
         &notification_title(&1, %{})}
      ]

      # The structured-payload enums (food/water amount, bathroom kind) render through
      # `log_summary/2`; a payload holding only that field renders only its label.
      payload =
        for type <- LogEntry.types(),
            {field, values} <- Map.get(LogEntry.spec(type), :enums, %{}),
            do: {"#{type}.#{field}", values, &log_summary(type, %{field => &1})}

      schema ++ payload
    end

    # Under zh_TW a label must differ from its raw value *and* from the English label:
    # an untranslated msgid ("Cat") already differs from the raw value ("cat"), so the
    # raw-value comparison alone would pass a label that ships in English. It must also
    # differ from what the helper renders for a value it has never heard of — a lost
    # clause can land in a catch-all that is itself translated (a water `amount` of
    # "high" would read as the generic "Water").
    test "every enum value renders its own zh_TW label" do
      english =
        for {name, values, label} <- enums(),
            value <- values,
            into: %{},
            do: {{name, value}, label.(value)}

      untranslated =
        Gettext.with_locale(Goodmao2Web.Gettext, "zh_TW", fn ->
          for {name, values, label} <- enums(),
              fallback = label.("__no_such_value__"),
              value <- values,
              rendered = label.(value),
              rendered in [value, "", english[{name, value}], fallback],
              do: "#{name} #{inspect(value)} renders #{inspect(rendered)}"
        end)

      assert untranslated == [],
             """
             These enum values have no zh_TW label of their own:

               #{Enum.join(untranslated, "\n  ")}

             Add a clause to the label helper in Goodmao2Web.Helpers, then extract,
             merge and translate the new msgid in every locale.
             """
    end

    test "the English labels read as words, not identifiers" do
      assert translate_species("rabbit") == "Rabbit"
      assert translate_role("co_caretaker") == "Co-caretaker"
      assert translate_dose_status("missed") == "Missed"
      assert translate_vet_status("rejected") == "Not accepted"
    end
  end

  describe "format_datetime/1,2 (timezone-aware)" do
    test "shifts a UTC datetime into an explicit zone" do
      dt = ~U[2026-07-21 00:30:00Z]
      assert format_datetime(dt, "Asia/Taipei") == "2026-07-21 08:30"
      assert format_datetime(dt, "Etc/UTC") == "2026-07-21 00:30"
    end

    test "uses the process active timezone for /1" do
      dt = ~U[2026-07-21 00:30:00Z]
      Timezone.put_current("Asia/Taipei")
      assert format_datetime(dt) == "2026-07-21 08:30"
      Timezone.put_current("Etc/UTC")
      assert format_datetime(dt) == "2026-07-21 00:30"
    end

    test "nil renders empty" do
      assert format_datetime(nil) == ""
      assert format_datetime(nil, "Asia/Taipei") == ""
    end
  end

  describe "format_date/1,2 (timezone-aware)" do
    test "shifts a UTC datetime's date into the zone (can cross midnight)" do
      # 23:30 UTC is already the next day in Taipei (+8).
      dt = ~U[2026-07-21 23:30:00Z]
      assert format_date(dt, "Asia/Taipei") == "2026-07-22"
      assert format_date(dt, "Etc/UTC") == "2026-07-21"
    end

    test "a plain Date is zoneless and formatted as-is" do
      assert format_date(~D[2026-07-21], "Asia/Taipei") == "2026-07-21"
    end

    test "nil renders empty" do
      assert format_date(nil) == ""
    end
  end

  describe "message_push_payload/2" do
    test "names the sender and never carries the message text" do
      payload = message_push_payload(%{handle: "mimi", display_name: "Mimi"}, 7)

      assert payload.title == "New message"
      assert payload.body == "From @mimi"
      assert payload.url =~ "/messages/7"
      # The signature takes no body at all; this pins that nothing else smuggles one in.
      assert Map.keys(payload) |> Enum.sort() == [:body, :icon, :tag, :title, :type, :url]
    end

    test "falls back to the display name, then to no sender line" do
      assert message_push_payload(%{handle: nil, display_name: "Mimi"}, 7).body == "From Mimi"
      assert message_push_payload(nil, 7).body == ""
    end

    test "tags per conversation, so threads don't replace each other" do
      assert message_push_payload(nil, 7).tag == "message:7"
      assert message_push_payload(nil, 8).tag == "message:8"
    end
  end
end
