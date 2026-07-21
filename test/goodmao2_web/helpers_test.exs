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

  describe "translate_species/1" do
    test "labels every enum value (including the added species)" do
      for s <- Goodmao2.Pets.Pet.species() do
        label = translate_species(s)
        assert is_binary(label) and label != ""
      end

      assert translate_species("rabbit") == "Rabbit"
      assert translate_species("bird") == "Bird"
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
end
