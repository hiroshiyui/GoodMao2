defmodule Goodmao2.Logs.LogEntry do
  @moduledoc """
  A structured daily log entry — the clinical unit of the timeline.

  One table holds every entry; `type` is the discriminator and the strongly-typed
  structured payload lives in the `data` `jsonb` map. This keeps clinical queries
  first-class ("weight trend", "vomiting this week") while staying a single table,
  and lets species-specific extras ride along without a migration per species.

  Free-text `note` sits *alongside* the structured fields, never instead of them.
  Entries are soft-deleted via `deleted_at`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(food water bathroom vomit weight energy medication symptom vet_note life)
  @visibilities ~w(private limited public)

  # Types any caretaker can author from the pet page's QuickLog. `life` is a plain
  # daily-life note here — its caption is the base `note`; media enrichment is deferred.
  # `vet_note` is excluded: it is vet-only and authored through its own gated path.
  @quicklog_types ~w(food water bathroom vomit weight energy medication symptom life)

  def types, do: @types
  def quicklog_types, do: @quicklog_types
  def visibilities, do: @visibilities

  schema "log_entries" do
    field :recorded_by_user_id, :id
    field :type, :string
    field :occurred_at, :utc_datetime
    field :note, :string
    field :visibility, :string, default: "limited"
    field :data, :map, default: %{}
    field :deleted_at, :utc_datetime

    belongs_to :pet, Goodmao2.Pets.Pet

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or editing a log entry.

  Validates the common fields, refuses a future `occurred_at`, and dispatches to
  a per-type payload validation so each subtype's structured fields are enforced.
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:pet_id, :type, :occurred_at, :note, :visibility, :data])
    |> put_default_occurred_at()
    |> validate_required([:pet_id, :type, :occurred_at])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_length(:note, max: 2000)
    |> validate_not_future(:occurred_at)
    |> validate_data()
    |> validate_life_note()
  end

  # A daily-life log carries no clinical fields — its content is the caption (the base
  # `note`). Until media enrichment lands, a life entry with no note would be empty, so
  # require one. (Other types may leave `note` blank alongside their structured data.)
  defp validate_life_note(changeset) do
    if get_field(changeset, :type) == "life" do
      validate_required(changeset, [:note])
    else
      changeset
    end
  end

  defp put_default_occurred_at(changeset) do
    if get_field(changeset, :occurred_at) do
      changeset
    else
      put_change(changeset, :occurred_at, DateTime.utc_now() |> DateTime.truncate(:second))
    end
  end

  defp validate_not_future(changeset, field) do
    case get_field(changeset, field) do
      %DateTime{} = dt ->
        if DateTime.after?(dt, DateTime.utc_now()),
          do: add_error(changeset, field, "cannot be in the future"),
          else: changeset

      _ ->
        changeset
    end
  end

  # --- Per-type structured payload validation -------------------------------
  #
  # Each spec is {required_enums, required_strings, optional}. Enum fields must be
  # one of the allowed values; required strings must be present; everything is
  # coerced through the sanitized data map so unknown keys are dropped.

  @specs %{
    "food" => %{
      enums: %{"amount" => ~w(full partial refused)},
      required: ["amount"],
      strings: ["food_type"],
      numbers: ["portion_grams"]
    },
    "water" => %{
      enums: %{"amount" => ~w(normal low high)},
      required: ["amount"],
      strings: [],
      numbers: ["volume_ml"]
    },
    "bathroom" => %{
      enums: %{"kind" => ~w(urine stool)},
      required: ["kind"],
      strings: ["consistency"],
      booleans: ["has_blood", "straining"]
    },
    "vomit" => %{
      required: ["count"],
      numbers: ["count"],
      strings: ["contents"]
    },
    "weight" => %{
      required: ["weight_grams"],
      numbers: ["weight_grams"]
    },
    "energy" => %{
      required: ["level"],
      numbers: ["level"],
      strings: ["mood"]
    },
    "medication" => %{
      required: ["medication_name", "dose"],
      strings: ["medication_name", "dose"]
    },
    "symptom" => %{
      required: ["symptom", "severity"],
      strings: ["symptom"],
      numbers: ["severity"]
    },
    "vet_note" => %{
      required: ["assessment"],
      strings: ["assessment", "recommendation"]
    },
    "life" => %{}
  }

  def spec(type), do: Map.get(@specs, type, %{})

  defp validate_data(changeset) do
    type = get_field(changeset, :type)
    data = get_field(changeset, :data) || %{}
    spec = Map.get(@specs, type)

    cond do
      changeset.errors[:type] != nil ->
        changeset

      is_nil(spec) ->
        changeset

      true ->
        {clean, errors} = sanitize(data, spec)

        changeset = put_change(changeset, :data, clean)

        Enum.reduce(errors, changeset, fn {key, msg}, cs ->
          add_error(cs, :data, "#{key} #{msg}")
        end)
    end
  end

  defp sanitize(data, spec) do
    enums = Map.get(spec, :enums, %{})
    strings = Map.get(spec, :strings, [])
    numbers = Map.get(spec, :numbers, [])
    booleans = Map.get(spec, :booleans, [])
    required = Map.get(spec, :required, [])

    {clean, errors} =
      Enum.reduce(enums, {%{}, []}, fn {key, allowed}, {acc, errs} ->
        case blank_to_nil(data[key]) do
          nil ->
            {acc, errs}

          val ->
            if val in allowed,
              do: {Map.put(acc, key, val), errs},
              else: {acc, [{key, "is invalid"} | errs]}
        end
      end)

    {clean, errors} =
      Enum.reduce(strings, {clean, errors}, fn key, {acc, errs} ->
        case blank_to_nil(data[key]) do
          nil -> {acc, errs}
          val when is_binary(val) -> {Map.put(acc, key, String.slice(val, 0, 200)), errs}
          val -> {Map.put(acc, key, to_string(val)), errs}
        end
      end)

    {clean, errors} =
      Enum.reduce(numbers, {clean, errors}, fn key, {acc, errs} ->
        case coerce_number(data[key]) do
          :blank -> {acc, errs}
          {:ok, num} -> {Map.put(acc, key, num), errs}
          :error -> {acc, [{key, "must be a number"} | errs]}
        end
      end)

    {clean, errors} =
      Enum.reduce(booleans, {clean, errors}, fn key, {acc, errs} ->
        {Map.put(acc, key, truthy?(data[key])), errs}
      end)

    errors =
      Enum.reduce(required, errors, fn key, errs ->
        if Map.get(clean, key) in [nil, ""], do: [{key, "is required"} | errs], else: errs
      end)

    {clean, errors}
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp coerce_number(nil), do: :blank
  defp coerce_number(""), do: :blank
  defp coerce_number(n) when is_number(n), do: {:ok, n}

  defp coerce_number(s) when is_binary(s) do
    case Integer.parse(s) do
      {int, ""} ->
        {:ok, int}

      _ ->
        case Float.parse(s) do
          {float, ""} -> {:ok, float}
          _ -> :error
        end
    end
  end

  defp coerce_number(_), do: :error

  defp truthy?(v), do: v in [true, "true", "on", "1", 1]
end
