---
name: a11y-engineering
description: Perform project-wide accessibility (a11y) engineering across GoodMao2's Phoenix/LiveView web layer — auditing and fixing semantic HEEx, WAI-ARIA roles/states/names, keyboard operability and focus management, forms, colour contrast against the WCAG-verified Terracotta+Teal palette, colour-not-alone signalling for clinical flags, reduced-motion, live regions, and localized accessible names — then report findings by severity, apply fixes, and verify with mix precommit.
---

Accessibility is a **hard product invariant, not a nicety** — AGENTS.md states it directly:
"**Accessibility-first:** every meaningful element carries a stable, semantic `id`/`class`."
This skill **formalizes that invariant**. Use semantic HTML, correct roles/states/properties,
keyboard operability, and accessible names so GoodMao2 works for assistive technology, and so
the LiveView tests (which locate elements by their stable semantic `id`/`class`) keep passing.
A11y is also a **care** issue here: people log the health of pets they love and sometimes
grieve — the interface must never become a barrier at a hard moment.

This skill audits the **web layer** (`lib/goodmao2_web/`) — HEEx templates, Phoenix function
components in `core_components.ex` / `layouts.ex`, and the LiveViews under
`live/pet_live/`. The three contexts under `lib/goodmao2/` affect a11y only indirectly (error
copy, status codes). For a broader review use `code-review` (it has a quick a11y pass); this
skill is the deep, project-wide accessibility sweep and fix.

Scope note: the app is **localized (en / zh_TW / ja_JP)**. That is not a separate concern from
a11y — an `aria-label` that is an English literal is both an i18n bug and an a11y bug (AGENTS.md:
"All user-visible copy goes through `gettext()` (flash, templates, `aria-*`)").

---

## Step 1 — Orient

- Read `CLAUDE.md`, the **GoodMao2 section of `AGENTS.md`** (the accessibility-first and Gettext
  invariants), and skim `doc/roadmap.md` for role/UX intent. The clinical-flag log types and the
  gentle end-of-care path are the a11y-sensitive surfaces.
- Inventory the surfaces to audit — every HEEx template and component:
  - Layouts / shell: `lib/goodmao2_web/components/layouts.ex` (`Layouts.app`, `flash_group`,
    `theme_toggle`) and `layouts/root.html.heex` (the `<html lang>`, `<head>`).
  - Core components: `lib/goodmao2_web/components/core_components.ex` (`flash`, `button`,
    `input`, `error`, `header`, `table`, `list`, `icon`).
  - LiveViews: `lib/goodmao2_web/live/pet_live/{index,form,show,access,end_of_care}.ex` and the
    auth/settings LiveViews under `live/user_live/`.
  - Public surface: `controllers/page_html/home.html.heex` (the landing page).
- Note the toolchain — there is **no dedicated static a11y linter** in this stack.
  `mix precommit` (compile-as-errors + format + test) is the gate; the
  ConnCase LiveView tests assert on the semantic `id`/`class` anchors, so a11y regressions that
  break those anchors surface as test failures. Reason through the criteria below manually.

---

## Step 2 — Semantic HEEx & landmark structure  (the north star)

The goal: **every element locatable by role + accessible name**, no `<div>` soup — and every
meaningful element carrying a stable semantic `id`/`class` (AGENTS.md invariant; loop items
derive an id from the record, e.g. `id={"log-#{entry.id}"}`).

- **Landmarks**: `Layouts.app` already provides the `<header id="site-header">`, the
  `<nav id="site-nav" aria-label={gettext("Primary")}>`, and one `<main>`. Confirm each page
  contributes exactly one `<main>` and does not introduce a second unlabelled landmark of the
  same type; multiple same-type landmarks get distinct accessible names
  (`aria-label`/`aria-labelledby`).
- **Headings**: one `<h1>` per page (the `<.header>` component renders `<h1>`), no skipped
  levels (`h1→h2→h3`), headings describe sections — not styled `<div>`s. The timeline's date
  groups and the pet list are heading-worthy.
- **Lists are lists**: the timeline and pet list render as `<ul>/<li>` (or `<ol>` where order
  is meaningful), each entry ideally an `<article>`/`<li>` with an accessible name (the log
  type + time). The `<.list>` and `<.table>` core components already emit real list/table
  markup — reuse them rather than hand-rolling `<div>` grids.
- **Native elements over ARIA**: prefer `<button>`, `<.link>` / `<a href>`, `<label>`, `<nav>`
  to `<div role="...">`. ARIA is the fallback, not the default ("No ARIA is better than bad
  ARIA"). Remove redundant roles (`<nav role="navigation">`).
- **Interactive semantics**: anything clickable is a `<button>` (or the `<.button>` component)
  or a `<.link>`, never a `<div>`/`<span>` with a `phx-click`. `<.link navigate=/patch=/href=>`
  navigates; `<button phx-click=>` acts. The `<.button>` component already switches between
  `<.link>` and `<button>` based on its attrs — let it.
- **Time**: timestamps use `<time datetime="…">` — the machine value is the UTC/ISO instant,
  the text is the localized display.

---

## Step 3 — Accessible names & ARIA state  (localized)

- **Icon-only controls have accessible names**: every icon-only control (the flash close
  button, the `theme_toggle` system/light/dark buttons, any one-tap QuickLog glyph) needs an
  `aria-label` **through `gettext()`**, never a bare literal. The flash close button is the
  pattern to copy: `aria-label={gettext("close")}`. Audit `theme_toggle` — its three buttons
  are icon-only and must each carry a localized `aria-label`.
- **The `<.icon>` convention**: `<.icon>` renders an empty `<span class={[@name, @class]}>` whose
  glyph is a pure-CSS mask — it has no text content, so it is decorative by default. When an
  icon sits **next to visible text** (a labelled button), that is fine. When an icon is the
  **only** content of a control, the control (not the icon) carries the `aria-label`. Where a
  decorative glyph could still be announced (e.g. the emoji in
  `<span aria-hidden="true">🐾</span>` in `Layouts.app`), keep it `aria-hidden="true"` — mirror
  that convention for any purely-decorative mark.
- **Images**: content images (pet photos, future LifeLog media) get meaningful `alt` via
  `gettext()`; purely decorative images get `alt=""`. Never leave `alt` unset.
- **State is exposed**: toggles/expanders use `aria-expanded`; the active nav item and the
  current theme/locale use `aria-current`; busy regions use `aria-busy`; disabled controls are
  genuinely `disabled` (the `<.button>`/`<.input>` globals pass `disabled` through) — not just
  styled.
- **Live regions**: async outcomes announce. The `flash_group` wrapper is already
  `aria-live="polite"` and each `<.flash>` is `role="alert"` — route saved-log / failed-write /
  validation outcomes through flash (or a scoped `aria-live` region) so PubSub-driven timeline
  updates in `PetLive.Show` are not silent. A silent success or silent failure on the log flow
  is an a11y bug.
- Verify names with the mental "accessibility tree" test: read each interactive element as
  *role + name* and confirm it is unambiguous out of visual context.

---

## Step 4 — Forms  (auth, PetForm, QuickLog, LifeLogForm, Access)

Forms are the heart of the app — logging must be effortless *and* accessible. Prefer the
`<.input>` core component, which already wraps each control in a `<label>`.

- Every input has a programmatically associated label — `<.input label={gettext("…")}>` wraps
  the control in `<label>` with the label `<span>`. Placeholder text is **not** a label. Any
  hand-written input outside `<.input>` must associate a `<label for=…>` to the input `id`.
- Required fields marked `required` (the `<.input>` global passes it through) with a visible
  indication that is **not** colour-only; grouped controls (radio sets, the log-type picker)
  wrapped in `<fieldset>` + `<legend>`.
- **Error handling**: the `<.error>` component renders each message with a
  `hero-exclamation-circle` icon and `text-error`. Ensure errors are also linked to their field
  via `aria-describedby`, the field carries `aria-invalid="true"` when `@errors != []`, and a
  form-level summary is announced (`role="alert"`). Error copy must be explicit about what the
  user can fix, never leak backend detail, and never mislabel an outage as "wrong password".
  Errors are localized through the `errors` Gettext domain (`translate_error/1`).
- Submit buttons have real `type="submit"`; the form works by keyboard (Enter submits) and the
  LiveView `phx-submit` / `phx-change` bindings do not depend on pointer events.

---

## Step 5 — Keyboard operability & focus management

- **Everything reachable and operable by keyboard**: no positive `tabindex`; no keyboard traps;
  any custom widget implements expected key handling (Esc closes a dialog/menu). Because the app
  is LiveView, confirm every `phx-click` target is a natively focusable element (`<button>` /
  `<a>`) so keyboard users can trigger it — a `phx-click` on a `<div>` is unreachable.
- **Visible focus**: a clear `:focus-visible` ring on every interactive element — daisyUI's
  focus ring uses the brand `--color-primary`; never `outline: none` in `app.css` or a utility
  class without an equivalent replacement. Confirm the ring stays visible on both the `light`
  and `dark` themes.
- **Focus moves sensibly**: opening a dialog/menu moves focus in and restores it on close; a
  `push_navigate`/`push_patch` route change or a destructive confirm (end-of-care) lands focus
  somewhere meaningful, not lost on `<body>`.
- **Skip link**: provide a "skip to main content" link at the top of `Layouts.app` (targeting
  the `<main>`) for keyboard users bypassing the header/nav. It may be visually `sr-only` until
  focused.
- Tab order follows visual/reading order — don't reorder with CSS in a way that desyncs from
  DOM order.

---

## Step 6 — Colour contrast & colour-not-alone  (the audited palette)

The palette in `assets/css/app.css` is **already WCAG-audited** — the `light` and `dark`
daisyUI themes use the WCAG-verified sRGB hexes with the passing ratios recorded inline (e.g.
primary terracotta `#b5482b` gives white text 5.35:1; the dark theme lightens hues so they pass
AA as fills *and* as text). **Preserve that discipline**: if you retune a hue, re-verify the
ratio and update the inline comment. Do not introduce new ad-hoc colours.

- **Contrast ≥ WCAG AA**: 4.5:1 for body text, 3:1 for large text (≥ 24px, or ≥ 19px bold) and
  for UI component / focus-indicator boundaries. When you add a new colour pairing, check the
  real token pair — do not assume.
- **The `--gm-*` Macaron tints carry dark text only.** `app.css` documents the seafoam / blush /
  sage / coral etc. surface tints as *light fills meant to CARRY dark text* (alerts, badges,
  decorative sections), scoped to the light theme — never as text colour on a light surface
  (they would fail contrast). Respect that scoping.
- **Never encode meaning in colour alone** (WCAG 1.4.1) — critical for the clinical flags. A
  blood / vomiting / urinary-emergency marker must carry **text and/or a heroicon and/or
  shape**, not just red. Status (active vs expired grant, vet-note vs owner note, private vs
  public visibility) needs a non-colour cue too — a label or icon, localized.
- **Reduced motion**: gate every animation/transition on the user's preference. This repo uses
  Tailwind's `motion-safe:` variant (`motion-safe:animate-spin` on the reconnect spinner) —
  reuse `motion-safe:` / `motion-reduce:` rather than unconditional animation.
- **Both themes**: the theme toggle sets `data-theme` on `<html>`; verify contrast and
  non-colour cues hold under both `light` and `dark`.
- Don't hard-pin font sizes in a way that breaks 200% zoom / user font scaling; ensure no
  horizontal scroll at 320px width or 200% zoom.

---

## Step 7 — Localized accessible names (i18n × a11y)

- **No bare string literals** in any user-perceivable a11y attribute — `aria-label`,
  `aria-description`, `alt`, `title`, `<legend>`, error text, live-region / flash messages — all
  go through `gettext()`. A hardcoded English `aria-label` is invisible to a zh_TW / ja_JP
  screen-reader user. (`Layouts.app` already does this: `aria-label={gettext("Primary")}`,
  `title={gettext("Administrator")}`.)
- Follow the **culture-first** rules (ADR-0002): accessible names use the same natural,
  localized wording as the visible copy — not transliterations. Enum-label translations and log
  summaries live in `Goodmao2Web.Helpers`; reuse them so the accessible name matches what's on
  screen.
- Set `<html lang>` correctly for the active locale (`root.html.heex`), and mark any inline
  foreign-language run with `lang` so screen readers switch voice.
- **Locale parity**: every new message key exists in **all three** locales. After adding any
  accessible-name string, run `mix gettext.extract && mix gettext.merge priv/gettext` and fill
  in `en` / `zh_TW` / `ja_JP` — a missing translation is an a11y gap for that locale.

---

## Step 8 — Automated & manual verification

There is no runtime a11y tool wired into this stack. Reason through contrast, name-from-content,
and ARIA validity manually against the criteria above, and lean on the test suite:

- The ConnCase LiveView tests (`test/goodmao2_web/live/…`) assert on the stable semantic
  `id`/`class` anchors — a11y-driven markup changes must keep those anchors intact (or update
  the tests in the same pass).
- If proposing a heavier verification, offer (don't silently add) an `axe-core` pass over the
  key flows (login, pet list, QuickLog, timeline, settings) via a browser driver — but do not
  add a heavyweight dependency without asking.

---

## Reporting

Present findings grouped by severity:

| Severity | Criteria |
|----------|----------|
| **Critical** | A barrier that blocks a task for AT/keyboard users: an unlabelled control on the log/auth flow, a keyboard trap, a `phx-click` on a non-focusable element, a form field with no accessible name, meaning conveyed by colour alone on a clinical flag |
| **Major** | Real degradation: missing landmark/heading structure, contrast failure below AA, missing focus management on a dialog/route change, error not linked to its field (`aria-describedby`/`aria-invalid`), a hardcoded (non-localized) accessible name, missing `motion-safe:` guard |
| **Minor** | Hardening/polish: redundant ARIA, missing skip link, decorative image without `alt=""`, decorative glyph not `aria-hidden`, missing `<time datetime>` |

For each finding cite **file:line**, name the WCAG criterion (e.g. 1.4.1, 2.4.7, 4.1.2),
describe who it breaks for (screen-reader / keyboard-only / low-vision / motor) and how, and
give a **concrete fix** (the exact HEEx / attribute change, `gettext()`-wrapped). If a category
was audited and is clean, **say so explicitly** — silence is not a pass.

---

## Fixing

Apply fixes for all **Critical** and **Major** findings directly, preferring the
**semantic-HTML / core-component** fix over an ARIA patch every time. Route every user-facing
string added for an accessible name through `gettext()` in **all three** locales, then run:

```bash
mix gettext.extract && mix gettext.merge priv/gettext   # sync en / zh_TW / ja_JP
mix precommit                                           # compile-as-errors + format + test
```

The sweep is not complete until `mix precommit` passes and the locales are in sync. When one
a11y defect is found (e.g. an unlabelled icon button), **sweep every component and LiveView for
the same class** before finishing — a11y bugs cluster by pattern (same icon-button idiom, same
form helper, same palette token). Localize, don't transliterate; choose the native, humane
wording in every culture.
