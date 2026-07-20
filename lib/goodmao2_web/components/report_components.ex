defmodule Goodmao2Web.ReportComponents do
  @moduledoc """
  Rendering for health-summary reports and the shared weight-trend chart.

  `weight_chart/1` is the single, CSP-safe inline-SVG weight chart used by both the live pet
  page (`PetLive.Show`) and the frozen report. `report_body/1` renders a report's frozen
  `content` snapshot (see `Goodmao2.Reports`) and is used by both the authenticated report
  LiveView and the anonymous, tokenized print page — so the two always look identical.
  """
  use Phoenix.Component
  use Gettext, backend: Goodmao2Web.Gettext

  import Goodmao2Web.CoreComponents, only: [icon: 1]

  import Goodmao2Web.Helpers,
    only: [
      format_kg: 1,
      format_date: 1,
      format_datetime: 1,
      log_type_label: 1,
      log_summary: 1,
      clinical_flags: 1
    ]

  @doc """
  A CSP-safe inline-SVG weight-trend chart over an oldest-first `series` of
  `%{at: DateTime, grams: number}`, with an sr-only data table for assistive tech.
  """
  attr :series, :list, required: true
  attr :id, :string, default: "weight-trend"

  def weight_chart(assigns) do
    series = assigns.series
    first = List.first(series)
    last = List.last(series)
    points = weight_points(series)
    delta = last.grams - first.grams

    assigns =
      assign(assigns,
        points: points,
        polyline: Enum.map_join(points, " ", &"#{&1.x},#{&1.y}"),
        last_point: List.last(points),
        latest_kg: format_kg(last.grams),
        delta_grams: delta,
        delta_kg: format_kg(abs(delta)),
        first_at: first.at,
        last_at: last.at
      )

    ~H"""
    <section id={@id} aria-labelledby={"#{@id}-heading"} class="card card-border bg-base-100 mt-6">
      <div class="card-body p-4">
        <div class="flex flex-wrap items-baseline justify-between gap-2">
          <h2 id={"#{@id}-heading"} class="text-lg font-semibold">{gettext("Weight trend")}</h2>
          <p class="flex items-baseline gap-2">
            <span id="weight-latest" class="text-2xl font-semibold">
              {gettext("%{kg} kg", kg: @latest_kg)}
            </span>
            <span id="weight-change" class="text-base-content/60 flex items-center gap-0.5 text-sm">
              <.icon name={weight_delta_icon(@delta_grams)} class="size-4" />
              {weight_delta_label(@delta_grams, @delta_kg)}
            </span>
          </p>
        </div>

        <figure class="mt-3">
          <svg viewBox="0 0 640 180" class="w-full" aria-hidden="true">
            <polyline
              points={@polyline}
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
              stroke-linejoin="round"
              vector-effect="non-scaling-stroke"
              class="text-primary"
            />
            <circle
              :for={p <- @points}
              cx={p.x}
              cy={p.y}
              r="3"
              fill="currentColor"
              class="text-primary"
            />
            <circle
              cx={@last_point.x}
              cy={@last_point.y}
              r="5"
              fill="currentColor"
              class="text-secondary"
            />
          </svg>
          <div class="text-base-content/50 mt-1 flex justify-between text-xs" aria-hidden="true">
            <time datetime={DateTime.to_iso8601(@first_at)}>{format_date(@first_at)}</time>
            <time datetime={DateTime.to_iso8601(@last_at)}>{format_date(@last_at)}</time>
          </div>
          <figcaption class="sr-only">
            <table>
              <caption>{gettext("Weight measurements")}</caption>
              <thead>
                <tr>
                  <th scope="col">{gettext("Date")}</th>
                  <th scope="col">{gettext("Weight")}</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={p <- @series}>
                  <td><time datetime={DateTime.to_iso8601(p.at)}>{format_datetime(p.at)}</time></td>
                  <td>{gettext("%{kg} kg", kg: format_kg(p.grams))}</td>
                </tr>
              </tbody>
            </table>
          </figcaption>
        </figure>
      </div>
    </section>
    """
  end

  @doc """
  Renders a report's frozen `content` snapshot: a header, a per-type count summary, the
  weight trend (if any), and the chronological entry list. Used by both the authenticated
  view and the anonymous print page.
  """
  attr :content, :map, required: true
  attr :period_start, :any, required: true
  attr :period_end, :any, required: true

  def report_body(assigns) do
    entries = assigns.content |> Map.get("entries", []) |> Enum.map(&decode_entry/1)

    weights =
      for e <- entries,
          e.type == "weight",
          is_number(e.grams),
          do: %{at: e.occurred_at, grams: e.grams}

    counts = entries |> Enum.frequencies_by(& &1.type) |> Enum.sort()
    pet = Map.get(assigns.content, "pet", %{})

    assigns =
      assign(assigns,
        entries: entries,
        weights: weights,
        counts: counts,
        pet_name: Map.get(pet, "name"),
        pet_species: Map.get(pet, "species"),
        total: length(entries)
      )

    ~H"""
    <div id="report-body">
      <dl
        id="report-meta"
        class="text-base-content/70 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm"
      >
        <dt>{gettext("Pet")}</dt>
        <dd class="font-medium break-words">{@pet_name}</dd>
        <dt>{gettext("Period")}</dt>
        <dd>{format_date(@period_start)} – {format_date(@period_end)}</dd>
        <dt>{gettext("Entries")}</dt>
        <dd class="tabular-nums">{@total}</dd>
      </dl>

      <section
        :if={@counts != []}
        id="report-counts"
        aria-labelledby="report-counts-heading"
        class="mt-6"
      >
        <h2 id="report-counts-heading" class="text-lg font-semibold">{gettext("Summary")}</h2>
        <ul class="mt-2 flex flex-wrap gap-2">
          <li :for={{type, n} <- @counts} id={"report-count-#{type}"} class="badge badge-ghost gap-1">
            <.icon name="hero-hashtag" class="size-3" />
            {log_type_label(type)}: <span class="tabular-nums">{n}</span>
          </li>
        </ul>
      </section>

      <.weight_chart :if={@weights != []} id="report-weight" series={@weights} />

      <section id="report-entries" aria-labelledby="report-entries-heading" class="mt-6">
        <h2 id="report-entries-heading" class="text-lg font-semibold">{gettext("Timeline")}</h2>
        <p :if={@entries == []} id="report-entries-empty" class="text-base-content/60 py-4">
          {gettext("No entries in this period.")}
        </p>
        <ol class="mt-3 space-y-3">
          <li :for={entry <- @entries} class="report-entry card card-border bg-base-100">
            <div class="card-body gap-1 p-3">
              <div class="flex flex-wrap items-baseline justify-between gap-2">
                <span class="font-medium">{log_type_label(entry.type)}</span>
                <time
                  datetime={entry.occurred_at && DateTime.to_iso8601(entry.occurred_at)}
                  class="text-base-content/50 text-sm"
                >
                  {format_datetime(entry.occurred_at)}
                </time>
              </div>
              <p class="text-base-content/80 text-sm">
                {log_summary(%{type: entry.type, data: entry.data})}
              </p>
              <ul :if={flags(entry) != []} class="flex flex-wrap gap-1">
                <li
                  :for={flag <- flags(entry)}
                  class={["badge badge-sm gap-1", flag_class(flag.level)]}
                >
                  <.icon name={flag.icon} class="size-3" /> {flag.label}
                </li>
              </ul>
              <p
                :if={entry.note not in [nil, ""]}
                class="text-base-content/60 text-sm italic break-words"
              >
                {entry.note}
              </p>
            </div>
          </li>
        </ol>
      </section>
    </div>
    """
  end

  defp flags(entry), do: clinical_flags(%{type: entry.type, data: entry.data})

  defp flag_class(:urgent), do: "badge-error"
  defp flag_class(:watch), do: "badge-warning"
  defp flag_class(_), do: "badge-ghost"

  # A frozen snapshot entry has string keys and an ISO-8601 occurred_at; decode into the
  # atom-keyed shape the Helpers rendering functions expect.
  defp decode_entry(e) do
    data = Map.get(e, "data") || %{}

    %{
      type: Map.get(e, "type"),
      occurred_at: parse_dt(Map.get(e, "occurred_at")),
      note: Map.get(e, "note"),
      data: data,
      visibility: Map.get(e, "visibility"),
      grams: data["weight_grams"]
    }
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp weight_points(series) do
    grams = Enum.map(series, & &1.grams)
    gmin = Enum.min(grams)
    gmax = Enum.max(grams)
    t0 = series |> List.first() |> Map.fetch!(:at) |> DateTime.to_unix()
    t1 = series |> List.last() |> Map.fetch!(:at) |> DateTime.to_unix()
    n = length(series)

    series
    |> Enum.with_index()
    |> Enum.map(fn {p, i} ->
      fx =
        cond do
          t1 > t0 -> (DateTime.to_unix(p.at) - t0) / (t1 - t0)
          n > 1 -> i / (n - 1)
          true -> 0.0
        end

      fy = if gmax > gmin, do: (p.grams - gmin) / (gmax - gmin), else: 0.5

      %{x: Float.round(6.0 + fx * 628.0, 1), y: Float.round(10.0 + (1.0 - fy) * 160.0, 1)}
    end)
  end

  defp weight_delta_icon(delta) when delta > 0, do: "hero-arrow-trending-up"
  defp weight_delta_icon(delta) when delta < 0, do: "hero-arrow-trending-down"
  defp weight_delta_icon(_delta), do: "hero-minus"

  defp weight_delta_label(delta, kg) when delta > 0, do: gettext("+%{kg} kg", kg: kg)
  defp weight_delta_label(delta, kg) when delta < 0, do: gettext("−%{kg} kg", kg: kg)
  defp weight_delta_label(_delta, _kg), do: gettext("no change")
end
