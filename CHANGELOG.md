# Changelog

All notable changes to GoodMao are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to adhere
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version of record is
the `version:` in `mix.exs`; a release tags it as `vX.Y.Z` (see the `release-engineering`
skill).

## [Unreleased]

**Upgrade notes.**

- **Erlang/OTP 29.1.1 and Elixir 1.20.4.** Production must move off OTP 28.5.0.6 / Elixir
  1.19.5 (`.tool-versions`). Elixir is now pinned to its
  OTP 29 build (`1.20.4-otp-29`). As before, the deploy playbook builds with the pinned runtime
  but does not install it, so run `ansible-playbook playbooks/setup-server.yml --tags elixir`
  first, from a checkout of the release being deployed. The deploy now stops before building
  if the release pins a runtime the server doesn't have.

### Changed

- **Erlang/OTP 28.5.0.6 → 29.1.1, Elixir 1.19.5 → 1.20.4.** Elixir 1.20's type checker flagged
  a few dead expressions (an unreachable `SafeClient` clause, an unused `require Logger`, and
  `&&` chains on calls that always return `:ok`); they are removed. No behaviour changes.
- **Type-checker warnings now fail the gate in `test/` too.** `mix precommit` and CI run
  `mix test --warnings-as-errors`. Before this, only `lib/` was checked. This was the gap that
  let two unpinned bitstring `size(...)` variables through (AGENTS.md: "The Elixir 1.20 type
  checker is a reviewer").
- **One Erlang/Elixir pin everywhere.** Ansible reads `erlang_version`/`elixir_version` from
  `.tool-versions` instead of keeping its own copy, so dev, CI, and production can't disagree.
  The deploy also checks that the release's pinned runtimes are installed before it builds.
  `Goodmao2.RuntimeVersionsTest` fails if CI, Ansible, or the docs drift from the pin, or if
  the tests run on a runtime other than the pinned one.
- **`mix goodmao.doctor`** accepts an asdf Elixir pin with an OTP suffix (`1.20.4-otp-29`)
  instead of warning that the running `1.20.4` doesn't match it.

## [1.4.0] - 2026-09-20

A correctness release. One fix changes what caretakers can see, so **read the upgrade note
before deploying**. Also a security patch on the HTTP client, accessibility fixes across every
form, and the first browser-driven tests in the project.

**Upgrade notes.**

- **QuickLog entries are shared again.** Entries logged through the web UI were being saved
  `private` — visible to nobody but whoever recorded them — instead of `limited`. Existing
  entries are left exactly as they are: this release does **not** rewrite anyone's stored
  visibility, because a `private` entry may have been meant privately even if the UI chose it.
  Entries logged from now on follow ADR-0004 and are visible to caretakers with an effective
  grant. If your users have been wondering why a co-caretaker or vet saw nothing they logged,
  this was why, and their old entries still need setting to Limited by hand.
- **No configuration or runtime change is required.** The Erlang/OTP and Elixir pins are
  unchanged from 1.3.0, and nothing in this release alters the deploy playbook's inputs.

### Security

- **`mint` 1.10.1** closes CVE-2026-82672 / GHSA-rj5m-69wp-cxq9 (MEDIUM): an unvalidated
  chunk-size line tail in the HTTP/1 client allows a response to be smuggled past a strict
  intermediary on a pooled connection. `mint` reaches the app through `req` → `finch`, which is
  what `WebPush.SafeClient` uses to reach third-party browser push endpoints over pooled
  connections, so the precondition is real. Found by `mix hex.audit`; `mix deps.audit` did not
  report it, which is why the gate keeps both databases.

### Fixed

- **QuickLog saved every entry `private`.** `visibility_select/1` builds its `<select>` from
  `LogEntry.visibilities()`, which lists `private` first, and QuickLog builds its form from an
  empty map — so the field arrived with no value, no option matched, and the browser selected
  the first. The server-side `|| "limited"` fallback never fired, because it only covers an
  absent parameter and the browser always sent one. The control also contradicted itself: the
  hint beneath it read `@field.value || "limited"`, explaining "limited" while submitting
  "private".
- **Form errors were not announced.** `<.input>` rendered its messages in a sibling element
  with no `id`, and gave the control neither `aria-invalid` nor `aria-describedby`. Anyone
  using a screen reader heard the field's label and nothing about what was wrong — the red ring
  was the only signal, which is also colour alone. Fixed for all four input kinds (text,
  select, textarea, checkbox), so every form in the app is covered: login, registration,
  QuickLog, the pet form, access grants, settings and two-factor. Where a field is already
  described — the visibility hint — the error joins that description rather than replacing it.
- **The theme toggle never said which theme was selected.** The choice was drawn only by a
  CSS-positioned pill, so its three buttons read as identical unpressed controls, and the cue
  is lost in forced-contrast modes as well. Each now carries `aria-pressed`, kept truthful by
  the same script that moves the pill, and re-synced after a LiveView patch. The control also
  renders twice (desktop bar and mobile menu) and carried no `id` at all, which is how the
  duplication went unnoticed.
- **Table rows could not be activated by keyboard.** `<.table>`'s `row_click` put `phx-click`
  on a `<td>`, which cannot take focus. The cell content now sits in a real button, with one
  tab stop per row rather than one per column. The component has no callers yet, so this is a
  trap removed rather than a bug users hit.
- **Buttons now state their type.** Twenty submit buttons relied on the HTML default, which
  also meant an action button added to any of those forms would have submitted it instead of
  running its `phx-click`. Behaviour is unchanged.

### Added

- **Browser-driven end-to-end tests** (`mix test.feature`) — thirteen tests driving a real
  Firefox through Wallaby and Selenium: the pet spine (sign in, add a pet, QuickLog a weight,
  and a second browser seeing that entry arrive over PubSub without reloading), a
  JavaScript-error crawl across every signed-in and guest page, the accessibility behaviour
  that only exists once scripts run, and the second factor — including a real WebAuthn
  registration ceremony through a WebDriver virtual authenticator. Until now nothing in the
  suite ran the client, which is how the QuickLog defect above stayed hidden behind a green
  build; it was found by the first browser test that logged an entry as an owner and looked
  for it in a co-caretaker's session.
- **`mix selenium.setup`** installs Selenium Server and GeckoDriver into the git-ignored
  `tmp/`, each pinned by SHA-256. GeckoDriver is built from its source crate because the
  0.37.x release binaries are signed by a Mozilla subkey revoked as compromised.

### Changed

- **Dependencies:** phoenix 1.8.14, phoenix_live_view 1.2.12, tz 0.28.4 (a newer IANA release),
  swoosh 1.28.1, and the Rust NIF lockfile refreshed. daisyUI re-vendored at 5.7.42, which
  starts treating `[aria-current]` on a menu item as active styling — the locale dropdown
  already marked its current option both ways, so nothing renders differently.
- Feature tests are excluded from `mix test` and from `mix precommit`: the gate stays runnable
  without a browser. Selenium listens on 4445 rather than its default 4444, so a server another
  checkout left running cannot be mistakenly reused.

## [1.3.0] - 2026-09-18

A project-wide security audit and its follow-up. There are no new features, but the upgrade
isn't drop-in, and several fixes are serious: **upgrading promptly is strongly recommended**,
especially for the Erlang/OTP update and the second-factor fixes.

**Upgrade notes.**

- **Erlang/OTP 28.5.0.6.** Production must move off 28.3.1 (`.tool-versions`,
  `erlang_version`). The deploy playbook *builds with* the pinned runtime but does not install
  it, so run `ansible-playbook playbooks/setup-server.yml --tags elixir,nginx` first. The
  `nginx` tag applies the access-log token redaction; it too is outside the deploy playbook.
- **Deploys pin a commit.** `deploy-goodmao2.yml` now requires `release_commit`, the full SHA
  the release tag names in your own clone (`git rev-parse v1.3.0^{commit}`). It builds exactly
  that commit and aborts if the tag on the remote now names anything else.
- **Per-server Erlang cookie.** The release refuses to start without its own `RELEASE_COOKIE`.
  The playbook generates one per server, but a remote console now needs the environment file
  loaded (see `doc/deployment.md`).
- **One-time logout.** The session cookie is now encrypted, so signed-in users without
  "remember me" must log in again once.

### Security

- **Erlang/OTP 28.3.1 → 28.5.0.6.** 28.3.1's TLS client could be made to accept a forged
  server certificate (CVE-2026-55953, critical; CVE-2026-42789 and CVE-2026-42790, high).
  Both outbound TLS clients were exposed to anyone on the network path: Amazon SES, whose
  emails carry magic-link tokens, and Web Push.
- **Erlang distribution was open to the other accounts on the host** (ADR-0021). The release
  joined distribution with the cookie `mix release` writes to `releases/COOKIE`, which a deploy
  left mode `0644`. Any account on the host, including the co-hosted Baudrate's, could read it
  and run arbitrary code inside GoodMao2's node, and the node listened on every interface.
  The release now refuses `start`, `remote`, `rpc`, `stop` and `pid` without its own
  `RELEASE_COOKIE` (`env/release_cookie`, `0600`, generated once per server) and listens on
  `127.0.0.1` only.
- **Open pet pages kept streaming entries after access ended.** Revoking, expiring or demoting
  a grant, or hiding the history, disconnected nothing, and the page rendered every live update
  it was sent. An ex-caretaker's forgotten tab, or a vet's after their time box ended, kept
  receiving the pet's new health entries; a demoted owner kept getting other people's private
  ones. Every pushed entry is now re-read with the viewer's access as it stands now, and the
  hidden-history flag is always read from the database, never from a page's snapshot.
- **A stolen password allowed an unlimited online TOTP brute force.** The 5-attempt cap lived
  in the session cookie, and posting every guess with the cookie from before the first failure
  meant the count never rose. Attempts are now charged to a per-user, server-side hourly
  budget before they are evaluated.
- **Second-factor races.** Two concurrent requests with the same TOTP code could both succeed;
  verification and replay claim are now one conditional update. A parallel forced-setup
  session opened with a stolen password could complete on the admin's own enrollment, or
  overwrite it; setup now finishes only on the secret its own session enrolled.
- **2FA settings checked sudo mode only when the page opened**, so a tab left open past the
  window could still turn off the authenticator or enroll someone else's. Every change now
  re-checks.
- **Unauthenticated memory exhaustion through the login throttle.** Failed attempts were keyed
  by the raw submitted address and kept for an hour, so megabyte-sized addresses could exhaust
  node memory. Keys are now digests, and oversized or non-string addresses are refused before
  the throttle or the database see them (a non-string address also no longer returns a 500).
- **Revoked caretakers could keep messaging, and push-notifying, an owner.** The shared-pet
  gate applied only when a conversation started; see *Changed*.
- **The session cookie was readable, not just tamper-proof.** During forced 2FA setup it
  carried the raw TOTP seed. It is now encrypted.
- **Registration was revealed by response time.** Only a registered address waited on the
  outbound mail call; magic-link mail is now sent from a background job.
- **Bearer tokens reached logs.** Magic-link, email-confirmation and share tokens in URL paths
  were written by both Phoenix and nginx (including in Referer headers), and token and
  second-factor params weren't filtered. All are now kept out of logs.
- **A vet verdict could apply to credentials nobody reviewed**, if the applicant re-submitted
  between the admin loading the queue and deciding. Stale verdicts are now refused.
- **Another user's email was shown as their name** in conversations and entry edit history when
  they had no handle or display name.
- **Media files were readable by other accounts on the host**, including staged raw uploads
  that still carry EXIF/GPS. The store is now `0700` and the service runs with `UMask=0077`.
- **Defense in depth.**
  - Entries, reports, medication schedules and grants passed alongside a pet must belong to
    it, and edits can no longer move an entry or schedule to another pet.
  - ffmpeg and ffprobe may read local files only.
  - Web Push response bodies are never read, and push jobs have a hard deadline.
  - Malformed notification and report ids no longer crash the page.
- **Supply chain.** Deploys build a tag-verified commit, GitHub Actions are pinned by commit SHA,
  and CI now runs `mix hex.audit` alongside `mix deps.audit`.

### Changed

- **Messaging follows the shared pet.** Once two people no longer share a pet, their
  conversation stays readable but can't be replied to, and the reply box explains why. Sending
  is capped at 120 messages per user per hour.
- **Hiding a pet's history also hides its medications**: schedules and doses aren't shown,
  changes are refused, and no dose reminders are sent while hidden (ADR-0003, ADR-0019).
- **Security events are logged**: failed and throttled logins, second-factor failures and
  lockouts, and changes to second factors, security keys, passwords and emails. Lines carry
  user ids and the client address, never the secret involved.
- **Dependabot** now also covers the Rust NIF crate, the Rust toolchain, and the frontend
  toolchain manifest.

## [1.2.2] - 2026-09-13

A dependency-maintenance release. No application behaviour changes, but it patches six
published advisories in the web server, HTTP client, database driver, and LiveView —
**upgrading promptly is recommended for any deployment serving HTTP/2**.

### Security

- **Bandit 1.12.4 → 1.12.5** — CVE-2026-74836 (HIGH): HTTP/2 connection-window starvation
  could pin Plug processes indefinitely; CVE-2026-75484 (MEDIUM): HTTP/2 header values
  containing CR, LF, or NUL reached the application unvalidated.
- **Mint 1.9.3 → 1.10.0** (transitive) — CVE-2026-82728 (HIGH): unbounded HTTP/1 status-line
  and chunk-extension buffering allowed memory exhaustion; CVE-2026-82729 (MEDIUM): quadratic
  chunk-size parsing allowed CPU exhaustion. Affects outbound requests (Web Push).
- **Postgrex 0.22.3 → 0.22.4** — CVE-2026-66838 (MEDIUM): SQL injection via the `:comment`
  option of `Postgrex.stream/4`.
- **Phoenix LiveView 1.2.7 → 1.2.11** — CVE-2026-64941 (LOW): open redirect in
  `validate_local_url!/2` via ASCII tab, LF, and CR.

None of these were reported by `mix deps.audit`; all came from `mix hex.audit`.

### Changed

- Phoenix 1.8.9 → 1.8.13; Oban 2.23.0 → 2.24.1 (no new Oban migration — the schema is
  already at v14); Req 0.6.3 → 0.7.4; Swoosh 1.26.3 → 1.28.0; telemetry_metrics 1.2.0.
- `phoenix_live_dashboard` `~> 0.8.3` → `~> 0.9.1` and `dns_cluster` `~> 0.2.0` → `~> 0.3.0`
  (constraint edits in `mix.exs`).
- Frontend toolchain: esbuild 0.25.4 → 0.28.2, Tailwind CSS 4.1.12 → 4.3.3, and the vendored
  daisyUI 5.0.35 → 5.7.37. Component styling may shift subtly across the daisyUI update.
- Rust toolchain 1.95.0 → 1.98.1 (`rust-toolchain.toml`); build hosts install it on the next
  build.
- Dev/test tooling: Sobelow 0.15.0, phoenix_live_reload 1.7.0, lazy_html 0.1.12.

## [1.2.1] - 2026-08-03

A project-wide review (correctness, security, tests, i18n, documentation, accessibility).
No new features — this release is fixes, and two of them are serious enough that **upgrading
promptly is worthwhile for any deployment with second-factor authentication enabled**.

### Security

- **A stolen password alone could complete a second-factor login.** `POST
  /users/two-factor/complete` is the *tail* of the forced-enrollment flow and verifies no
  factor itself, but it issued a session token to anyone holding a pending-2FA marker whose
  account had any factor enrolled — which is precisely the state of every user the instant
  their password verifies. An attacker with a phished or reused password reached the pending
  stage legitimately, posted to that endpoint with no code, key, or recovery code, and was
  logged in. The same gap let them open the enrollment page, which issued a *fresh* TOTP
  secret and, on confirm, silently replaced the victim's real factor and wiped their recovery
  codes. Both paths now require a marker set only on the enrollment branch, so a user who owes
  proof of a factor can neither skip it nor re-enroll around it. **This breaks the ADR-0013
  invariant that "2FA passed ≡ a session token exists", and a successful bypass is
  indistinguishable from a normal login in the logs — operators should consider invalidating
  existing sessions and checking whether any user's TOTP secret changed unexpectedly.**
- **A caretaker demoted to `viewer` could still delete the entries they had recorded.**
  Deleting checked only that the caller recorded the entry, never that they still held write
  capability — so demoting someone (the deliberate way to withdraw write access while keeping
  read) left them able to erase the history they had logged. Editing and deleting now both
  require `:write` *and* recorder, with an owner short-circuit.
- **Cloned security keys were accepted.** ADR-0013 and the function's own docstring both
  stated that WebAuthn sign-count regression was enforced; the library returns the counter and
  explicitly leaves the comparison to the caller, and nothing performed it. Now enforced per
  WebAuthn §7.2, exempting only authenticators that report no counter at all.
- **`Logs` reads did not require a grant.** Every read resolved a role and filtered by entry
  visibility, which for a caller with *no* effective grant stripped only `private` entries —
  so a stranger handed a pet struct would have received its `limited` and `public` health
  history. Not reachable through the web layer, whose callers all resolve pets through
  `Pets.fetch_pet/3` first, but the context documents itself as safe on its own. All four read
  paths now check `:read` first.
- **`bandit` 1.12.0 → 1.12.4** for [CVE-2026-65623](https://osv.dev/vulnerability/EEF-CVE-2026-65623)
  (HIGH): quadratic CPU blow-up reassembling fragmented WebSocket messages. Unauthenticated,
  and every GoodMao session is a WebSocket. The gate had passed on the vulnerable build
  because `mix_audit`'s advisory database lacks this entry, so `mix precommit` now consults
  hex.pm's database as well — the two do not agree, and one alone is not enough.

### Fixed

- **A single hostile or pathological upload could stop background work site-wide.**
  `System.cmd/3` cannot take a timeout, so a wedged ffmpeg held its job slot indefinitely; all
  nine workers shared one queue, so enough of them would stall medication reminders, Web Push,
  and the bell feed until a restart. ffmpeg and ffprobe now run under a hard wall-clock
  deadline that kills the child process, and media purification has its own `:media` queue so
  it cannot starve the rest.
- **The unauthenticated rate limiters grew without bound.** Both keyed ETS rows by an
  attacker-supplied email address and never removed them; because the limit is per-address, a
  flood of distinct addresses was never throttled and grew the table until the node ran out of
  memory. Both now sweep expired windows.
- **A medication dose could be announced twice.** Reminders were sent and *then* stamped, so a
  sweep that overran its 15-minute interval — or an Oban retry after a partial failure — could
  re-read the same unstamped slot and push every caretaker a second alert for one pill. The
  slot is now claimed with a conditional update before anything is sent.
- **A malformed URL crashed instead of showing "not found".** A non-numeric `:id` reached Ecto
  as a cast error across eight LiveView mounts, producing a 400 page or a dead LiveView rather
  than the existence-hiding not-found every id lookup here promises. Normalized at the context
  boundary, bounded so an oversized value cannot overflow Postgres `bigint` either.
- **A dismissed notification no longer arrives as a phone push**, and a failed revision insert
  returns an error rather than raising.
- **Secondary text failed WCAG AA on the light theme.** The palette's colour *pairs* clear AA,
  but the opacity modifiers used for timestamps and explanatory copy did not —
  `text-base-content/50` measured 3.11:1 and `/60` 4.15:1 against a 4.5:1 floor. Informational
  text now uses `/70` (5.67:1 light, 7.11:1 dark).
- **Keyboard focus was invisible on the avatar upload buttons**, whose `outline-none` utility
  silently beat the app's zero-specificity focus ring instead of adjusting it.
- **The QuickLog chips no longer claim to be tabs.** `role="tab"` promises arrow-key navigation
  and an associated panel, neither of which exists; they are toggle buttons and now say so.
  A failed one-tap log is also announced (it changed nothing else on screen), and unread
  markers are no longer conveyed by colour alone.
- **Validation errors were shown in English in every locale**, with `%{count}` placeholders
  rendered literally, because they bypassed the translation layer entirely. Fifteen custom
  changeset messages were also missing from the catalogue; all are now translated into
  `zh_TW` and `ja_JP`.
- **The hamburger menu's items are right-aligned**, as intended.

### Changed

- Documentation was audited against the code. Several claims were wrong rather than merely
  stale — a payload field named `is_straining` that is `straining`, a `medication` field that
  does not exist, ADR-0005's binding "atomic create" decision that the async pipeline
  superseded, and an "unvalidated ranges" gap that `architecture.md` described as already
  enforced (now filed as roadmap §1b). `Accounts`, the app's security-critical context, gained
  a real `@moduledoc`; the avatar hard-delete is now recorded as a deliberate exception to
  ADR-0008 rather than an undocumented one.
- 18 tests added, chiefly the expired- and revoked-grant denial paths at every context
  boundary — previously asserted once at `Pets.can?` and trusted transitively everywhere else.
- **CI now builds the Rust NIF reliably.** `_build/<env>/lib/goodmao2/priv` is a symlink to
  the project's `priv/`, so the git-ignored `priv/native/*.so` was never inside the cached
  `_build` archive — and on a cache hit the restored manifests told Mix the app was already
  compiled, so `mix compile` no-oped and never rebuilt it. The shared object now has its own
  cache, keyed on the crate's sources and toolchain rather than on `mix.lock`, plus a guard
  that forces a rebuild whenever it is absent.

## [1.2.0] - 2026-07-31

### Added

- **Media uploads show a live progress bar per file.** A multi-MB photo on a slow uplink gave
  no feedback between submit and the "processing" flash — a stalled upload and a slowly
  grinding one looked identical. Each selected file now renders a native `<progress>` bar
  (with a localized accessible name) that fills as the chunks stream, in both the QuickLog
  form and the entry page's media form. The bar stays at 0% until submit — uploads only start
  then — and the two forms' selected-files lists are now one shared `<.upload_file_list>`
  component.

## [1.1.1] - 2026-07-31

### Fixed

- **A media upload can no longer vanish silently when ffprobe is noisy.** On hosts with older
  ffmpeg (Debian 12's 5.1), probing a multi-frame phone JPEG emits decoder errors on stderr
  while still exiting 0. The purifier merged stderr into the JSON it parses, so the probe
  failed with a raw exception struct as the reason — and the purify worker's failure path
  crashed stringifying it *after* discarding the staged file, so the retry completed as a
  no-op: no media, no `media_failed` bell. ffprobe's stderr now stays out of the JSON (it goes
  to the application log), unparseable probe output is classified as a clean `probe_failed`,
  and the failure bell tolerates any reason shape — a failed upload is now always visible,
  never silent.

## [1.1.0] - 2026-07-31

### Added

- **A life log's photos and videos can now be managed after creation** from the single-entry
  page — the ADR-0005 follow-up. Anyone who may edit the entry can add files (through the
  same staging → purification pipeline as QuickLog, respecting the per-entry file cap and the
  hourly upload rate limit) and remove existing ones (a soft delete — the bytes stay). Neither
  counts against the nine-edit revision budget. The page now also follows the pet's live
  timeline topic, so a freshly purified file appears without a reload — and a failed upload no
  longer forces a second entry to try again.

### Fixed

- **Uploading a phone photo with an embedded second frame no longer fails purification.**
  Pixel/iPhone-style JPEGs carrying an Ultra HDR gain map or motion-photo frame — and animated
  PNGs — made the purifier's ffmpeg re-encode abort (the single-image muxer refuses a second
  frame), so the upload landed as a `media_failed` bell with no image attached. Still-image
  output is now pinned to the primary frame, which is also the purifier's contract: only the
  primary decoded pixels survive. GIF and WebP animation is unaffected.

## [1.0.5] - 2026-07-30

### Fixed

- **Images no longer re-download in full on every page load and PWA launch.** Media and
  avatar responses carried `private, no-cache` with no validator, so the browser had nothing
  to revalidate against and refetched every image's bytes each visit. Both endpoints now send
  a strong `ETag` and answer a matching `If-None-Match` with an empty `304`: a purified media
  object is immutable per id, so its id is the validator; an avatar's validator is its
  version — the same value that already cache-busts the URL — so a re-upload at the same URL
  invalidates correctly. The conditional check runs strictly *after* the per-request
  authorization (or share-token) check, so a revoked grant or un-shared entry still takes
  effect on the very next request; only the byte transfer is skipped, and a stranger
  presenting the correct `ETag` still gets the existence-hiding `404`.

### Changed

- **CI reuses the cached esbuild binary** instead of re-downloading it on every run.

## [1.0.4] - 2026-07-23

### Fixed

- **The last six untranslated strings now render in Chinese and Japanese.** Two authentication
  flashes, the mailbox conversation `aria-label`, and the weight chart's screen-reader table
  caption and column header had shipped with empty translations, falling back to English. Four
  of the six were an `aria-label` and a screen-reader-only table — so the only people who met
  the untranslated text were the ones the localization exists for. `zh_TW` and `ja_JP` are now
  at zero untranslated entries.

### Added

- **The locale-parity test asserts completeness and placeholder survival**
  (`test/goodmao2/locale_parity_test.exs`). The six strings above shipped while it passed, and
  it was right to pass: it checked that the catalogs carry the same msgids with no fuzzy
  entries, and they did. A merged-but-empty `msgstr` is structurally identical to a translated
  one, and Gettext falls back to the msgid silently — nothing broke and nothing warned. Every
  entry in a target locale must now carry a non-empty `msgstr` (`en` is the source locale,
  where empty legitimately means "identical to the msgid"), and every `%{placeholder}` in a
  msgid must survive into its translation — dropping one raises at render time in that locale
  alone. Both assertions were verified to fail on injected defects, not merely to pass.

### Documentation

- **A `v1.1.0` milestone chapter collects the deferred tail.** The v1.0.0 chapter had no
  unchecked items left, so the remaining work survived only as "Follow-up:" asides inside
  shipped entries. All of it is now one chapter with a stated theme — coordination — and each
  item names the failure mode it addresses: medication snooze/escalation, notification
  batching, dose-history retention GC, per-pet timezones, the media and sharing follow-ups, and
  the operational items a live deployment created (an offline backup of the GPG key that
  decrypts every deployment secret, one restore drill, and optional HSTS preload submission).
  Localization completeness is the first item shipped from it.
- The shipped v1.0.0 chapter **drops its 63 checkboxes** — a page of `[x]` reads as a form to
  fill in rather than a record of what was built. Three stale statuses in the ADR index
  (0004, 0005, 0009) were corrected: each said *deferred* while the ADR itself, and the code,
  said shipped.

## [1.0.3] - 2026-07-23

### Changed

- **Each log-entry visibility scope now says what it does.** The three scopes shipped as bare
  words — Private / Limited / Public — with nothing stating who can read the entry. The
  difference is not cosmetic: `private` hides an entry from co-caretakers and vets who
  otherwise read the whole timeline, and `public` is readable by anyone holding the link, with
  no account at all. A privacy control an owner has to guess at is one that gets set wrong.
  Every option now carries its meaning in the label (a native `<option>` renders one line of
  plain text, so it cannot travel any other way, and it is what a screen reader announces),
  the current choice is restated under the field and tied to it with `aria-describedby`, and
  the timeline badge explains itself on hover and to assistive technology. Both places an owner
  sets visibility render one shared component, so the wording cannot drift between them.
  Translated in all three locales. **No change to the data model, the read filters, or the
  owner-only rule** ([ADR-0004](doc/adr/0004-log-visibility.md)) — this only makes the existing
  behaviour legible.

### Documentation

- **The docs caught up with the product.** `README.md` described neither medication schedules,
  health reports, notifications and Web Push, messaging, avatars, per-viewer timezones, nor the
  installable app, and omitted Rust from the prerequisites although `mix compile` builds the NIF
  crate. `doc/architecture.md` was missing the `avatars` table, the native boundary, and the PWA
  entirely. `doc/roadmap.md` still listed "PWA / service worker / offline" as explicitly out of
  scope — now narrowed to **offline operation only**, which remains out of scope and always was
  the real objection. `AGENTS.md` and `CLAUDE.md` gained the PWA invariants, and
  `doc/web-application-development-common-practices.md` a section on the ways installability
  fails silently.

## [1.0.2] - 2026-07-23

### Fixed

- **Waking a phone no longer flashes a connection error.** Locking the screen or switching
  apps suspends the LiveView socket, so returning to the installed app showed a red "We can't
  find the internet" banner that cleared a moment later — alarming, and for a connection that
  was never really lost. The banners no longer reveal themselves the instant the socket drops;
  a `MutationObserver` watches the same `phx-client-error` / `phx-server-error` classes and
  shows them only after two seconds of sustained disconnection. Hiding stays immediate. A blip
  is now silent, while a real outage still reports, a beat later.

### Changed

- **Backups are documented as the hosting provider's responsibility.** Automatic whole-server
  backups cover Postgres and the media tree together, which an application-level `pg_dump`
  would not; `doc/deployment.md` now records the decision and what it implies on restore —
  notably that `SECRET_KEY_BASE` must be restored alongside the data, or encrypted 2FA secrets
  and the Web Push signing key become undecryptable.

## [1.0.1] - 2026-07-23

### Fixed

- **Security headers are sent once, by the application.** nginx repeated
  `X-Content-Type-Options` and `Referrer-Policy` at the server level, so every proxied page
  carried them twice. The values matched, so nothing was weakened — but it is the shape of
  the two bugs fixed in 1.0.0, where a duplicate quietly decided policy, and it left two
  places to edit for one decision. nginx now sets only HSTS, which it owns as the TLS
  terminator; responses it serves without the application (static files, the 502 page) set
  theirs explicitly.
- **`X-Frame-Options: DENY` no longer depends on the proxy.** Phoenix sends none of its own,
  leaning on the CSP `frame-ancestors` directive, so nginx had been the sole source — and
  removing it there would have dropped it silently. The application now sets it, as do the
  media and avatar controllers, whose byte-serving routes bypass the browser pipeline
  entirely.

## [1.0.0] - 2026-07-23

**GoodMao is live.** The first production release: running at
[goodmao.tw](https://goodmao.tw) on its own domain, over TLS, with mail delivery verified,
Web Push working end to end, and installable to a phone's home screen.

Nothing about the product changed at 1.0.0 — the features arrived across 0.1.0 through
0.3.2. What changed is the commitment: the version now communicates compatibility rather
than progress toward a first launch, and the data in production is real. Migrations from
here are expected to preserve it.

What a caretaker gets: pets with a full end-of-care lifecycle; a live, filterable timeline
of structured log entries with photos and video; per-pet sharing with family, co-caretakers
and vets, each at its own capability level; recurring medication schedules with reminders;
health summary reports that can be shared with a vet by link; a private mailbox; and an
in-site notification feed that can reach a phone as a push notification. In English,
Traditional Chinese and Japanese, in the viewer's own timezone, with two-factor
authentication available to everyone and required of the administrator.

### Fixed

- **HSTS is sent once, by nginx.** `force_ssl` left Plug.SSL's own HSTS default on while
  nginx sent a stronger policy, so the header went out twice. RFC 6797 has a browser
  process only the *first*, which meant the weaker one-year policy without
  `includeSubDomains` won — quietly making the site ineligible for the HSTS preload list
  despite the configuration asking for it. Plug.SSL now sets `hsts: false` and nginx owns
  the policy of record.
- **Static assets send one `Cache-Control`.** nginx's `expires` directive emits its own
  header alongside the explicit `add_header`, and again only the first counts — so
  fingerprinted assets advertised a bare `max-age` and lost `immutable`. Both static
  locations now set a single complete header.

## [0.3.2] - 2026-07-23

### Fixed

- **The installed app now shows a page when the phone is offline.** The service worker's fetch
  handler was a bare network passthrough, so a navigation with no connection produced the
  browser's own error page. It now precaches one self-contained static page and serves it when a
  navigation fails. Nothing else is cached deliberately: every GoodMao page is authenticated,
  per-viewer and live, so caching one would risk showing one person's records to whoever opens the
  app next. Only navigations are intercepted — assets, the LiveView socket and API calls go
  straight to the network.
- **nginx serves the web app manifest off disk.** The static-file location still carried a
  `site.webmanifest` filename inherited from a sibling project, which GoodMao never used, so
  `/manifest.json` missed the block and was proxied into the application on every request instead
  of being served beside the service worker.
- **CI builds the service worker before running the suite.** `priv/static/service_worker.js` is a
  git-ignored esbuild output, so a fresh checkout had nothing to serve and the PWA test failed on
  every run since 0.3.0 — including both release commits.

## [0.3.1] - 2026-07-23

### Fixed

- **The flash toast no longer overflows a phone screen.** It ran off the right edge and took its
  close button with it, so the message looked permanent with no way to dismiss it. The width was
  rem-only (`w-80` = 20rem), but the app's baseline is `html { font-size: 125% }` and the
  text-size control reaches 175% — rendering the toast at 400–560px against roughly 372px of
  usable width on a 412px phone. It is now capped by a viewport-relative `max-width`, keeping the
  intended width on larger screens while never exceeding the display at any text size.
- **Toasts respect the safe area in the installed app.** Being fixed-position they sit outside the
  app shell, so they missed the inset added in 0.3.0 and a top-anchored flash could render under
  the status bar.

## [0.3.0] - 2026-07-23

GoodMao installs to a phone's home screen. Pet care is logged on a phone at the moment it
happens, so a home-screen icon and a standalone window fit that far better than finding a
browser tab.

### Added

- **Installable as a Progressive Web App.** A web app manifest declares a `standalone` app that
  opens at **`/pets`** — where you actually work, not the landing page — with long-press
  **shortcuts** to Pets, Notifications, and Messages. Ships a generated paw icon set in the brand
  terracotta on cream, at 192 and 512 in both `any` and **`maskable`** purposes; the maskable
  variants keep the mark inside the safe zone so Android's adaptive shapes don't clip it. iOS
  ignores the manifest entirely, so it also gets an `apple-touch-icon` and the
  `apple-mobile-web-app-*` meta tags. `viewport-fit=cover` plus `env(safe-area-inset-*)` padding,
  scoped to `@media (display-mode: standalone)`, keeps the installed window clear of the notch and
  home indicator while leaving browser tabs untouched.
- Tests covering the installability contract, including that **every icon path the manifest
  references is actually served** — a missing `static_paths/0` entry 404s silently with no build
  error, and would otherwise only surface on a phone.

### Fixed

- **The service worker now registers on every page.** It was registered only by the `PushManager`
  hook, which mounts on the settings page alone, so a visitor who never opened settings had no
  service worker and could not meet the browser's installability criteria. This was the actual
  blocker to installing the app; the fetch handler had been in place for it all along.

### Known limitations

- The service worker is a network passthrough, so **the installed app shows the browser's offline
  error when there is no connection**. Genuine offline support is a larger design question for a
  LiveView app — the timeline is server-rendered over a WebSocket, so offline logging would need
  client-side queueing — and is deliberately deferred.

## [0.2.2] - 2026-07-23

Bug fixes found while putting the first production deployment through its paces. Two of them
made the app effectively unusable for entering Chinese or Japanese text — the locales half this
project is built for.

### Fixed

- **Typing into a QuickLog field no longer closes the form.** A `<details>` element's open state
  is DOM-only and absent from the server render, so every `phx-change` echo patched the "More
  options" panel back to closed on the very first keystroke — taking focus, and with it any
  in-flight IME composition, so bopomofo could never be composed into a character. A new
  `DisclosureState` hook remembers the state on `toggle` and re-applies it after each update.
  The panel closing affected every user; it was simply most destructive for IME input.
- **The mobile menu and locale switcher no longer snap shut on unrelated updates.** The live
  unread badges render *inside* `#nav-menu`, so a notification or message arriving over PubSub
  patched the element and closed an open menu. Both dropdowns now reuse `DisclosureState` with an
  opt-in `data-close-on-navigate`, which preserves state across unrelated patches while still
  dismissing the menu when one of its own links is tapped. Only `redirect`/`patch` navigation
  closes it — `phx:page-loading-start` also fires for ordinary events flagged `phx-page-loading`.
- **`phx-change` is now held while an IME is composing** (`blockPhxChangeWhileComposing`, which
  LiveView defaults to off) and re-fired on `compositionend`, so a server round-trip can no longer
  patch a focused input mid-character. Applies to every `phx-change` input in the app.
- **Setting a first password no longer asks for a password that does not exist.** Registration is
  magic-link only, so a new account has no `hashed_password`; the page nonetheless demanded users
  "confirm your current password" and marked the field required, so the browser blocked submission
  until they invented a value the server then discarded. It now titles itself **Set password**,
  explains that sign-in is by magic link, and omits the field — matching
  `User.validate_current_password/2`, which already skipped the check in this case. Accounts that
  do have a password see the unchanged gated form, and the controller's authoritative
  re-verification is untouched.

## [0.2.1] - 2026-07-23

A deployment-readiness release. No application code changed — the built artifact is functionally
identical to 0.2.0 — but the first production go-live surfaced gaps in the deployment
configuration and runbook that are fixed here.

### Fixed

- **Amazon SES region now points at the verified identity.** `aws_ses_region` defaulted to
  `us-east-1`, but the `goodmao.tw` identity is verified in `ap-northeast-3` (Osaka) and its Easy
  DKIM CNAMEs are region-pinned. SES identities are region-scoped, so the mismatch failed in the
  worst possible way: `config/runtime.exs` reads the variable at boot, the release starts cleanly,
  and then *every* send fails as an unverified identity. The value now carries a comment
  explaining why it must track the region the domain was verified in.

### Added

- **SOPS-encrypted production secrets** (`ansible/inventory/group_vars/all.sops.yml`) holding the
  database password, `secret_key_base`, and the SES IAM credential, with `.sops.yaml` pointed at
  the operator's GPG key. Only values are encrypted, so keys stay diffable; the file is safe to
  commit because decryption requires the operator's private key.
- **A first go-live checklist** in `doc/deployment.md` — an ordered, one-time path through the
  work Ansible cannot do for you: SES production access and DNS, admin registration and its
  mandatory 2FA enrolment, the runtime-only settings (Web Push VAPID keys, default timezone, media
  limits), and the database/media backups that are **not** yet automated.
- **The SES DNS contract**, documented: the five records the identity needs (three Easy DKIM
  CNAMEs plus the custom MAIL FROM `MX`/SPF pair, alongside DMARC), why SPF belongs on the
  `mail.` subdomain rather than the apex, and `dig` commands to verify each from outside. Includes
  the **Gandi trailing-dot trap** — an unterminated value silently gets the zone origin appended,
  which SES reports as a missing domain while the domain is demonstrably fine — and how to tell a
  local zone error from AWS-side DKIM key-publication lag. Also records that the zone has no apex
  `MX`, so nothing receives mail at the domain.
- **The SES-vs-SendGrid decision record**, capturing why SES was chosen for transactional auth
  mail (no monthly floor, deliverability parity at low volume, already integrated), the ~10-line
  Swoosh path to switch, and the conditions that would justify revisiting it.

## [0.2.0] - 2026-07-23

The full product build-out on top of the 0.1.0 MVP core: media and log editing, medication
coordination, the vet access model and health reports, in-site notifications and a private
mailbox with Web Push, two-factor authentication, a timezone display/input policy, profile
avatars, per-entry sharing, a trilingual UI, and the production deployment story. Everything is
backward compatible with 0.1.0; every user-visible string is localized in en / 台灣漢語 / 日本語.

### Added

#### Clinical logging & timeline

- **Weight trend chart** — the pet page shows the pet's weight over time as an inline SVG line
  chart (server-rendered, CSP-safe), appearing once there are two or more measurements. Readings
  are aggregated into one **daily-average** point per *local* day and the x-axis is partitioned
  strictly by calendar day (faint x/y scale lines; per-day dots dropped past ~45 days; the sr-only
  data table evenly sampled for long histories). It headlines the latest value and its signed
  change since the first day (a trend arrow **and** a +/− value, never colour alone); clicking a
  point reveals its date and weight (`WeightChart` JS hook, with a native `<title>` hover fallback
  in the static report). Fed by `Logs.weight_series/3` (visibility- and hidden-history-aware) and
  live over PubSub.
- **Log editing with an audited revision trail (ADR-0009)** — log entries can be edited on a
  dedicated entry page (`/pets/:pet_id/logs/:id`), and every real edit records an immutable
  snapshot of the prior state (type, data, note, time, visibility — never the share token) in a
  `log_entry_revisions` table. A no-op edit records nothing; the type is immutable on edit; and an
  entry may be edited at most nine times ("a cat's nine lives"), tracked by a denormalized
  `edit_count`. The revision history follows the entry's own read authorization, so it renders for
  readers, not just editors; the timeline marks edited entries.
- **One-tap QuickLog** — the common log values are each their own submit button (Food ate
  fully / partially / refused, Water normal / low / high, Bathroom urine / stool, Vomited),
  logging in a single tap; the full manual form moves into a "More options" disclosure.
- **Clinical flag chips on the timeline** — high-signal cues surface as urgent/watch chips
  (urinary blood/straining, not eating, repeated vomiting, severe symptom), each carrying an icon
  **and** text **and** a level-specific shape, never colour alone (WCAG 1.4.1). A single
  `Helpers.clinical_flags/1` is the source of truth, from which the calendar's day-cell tint is
  derived, so timeline and calendar can never disagree.
- **Calendar view for the pet timeline** — read the timeline as a month grid alongside the
  chronological list, toggled by a segmented control; each day cell shows its entry count plus a
  clinical cue, and picking a day expands that day's entries. Days bucket by **local** day.
- **Timeline pagination** — a per-page size control (persisted as a user preference), `:offset`
  paging on `Logs.list_entries`, and scroll-into-view on page changes.
- **Weight-unit-aware entry & display** — weight is entered and shown in the pet's `weight_unit`.
- **Daily-life logs (`life` type)** — any caretaker can author a daily-life note from QuickLog.
- **Per-entry share links (ADR-0004)** — an owner can mint an unguessable, optionally-expiring
  share token for a `public` entry; a single anonymous, existence-hidden shared-entry page serves
  it (`GET /entries/shared/:token`), and shared media rides the same token.

#### Media

- **Purified LifeLog photos & videos (ADR-0005)** — a daily-life log can carry images and video,
  uploaded through the app and **actively purified off the request path** (Oban): magic-byte
  typing, EXIF/GPS stripped by re-encode, images re-encoded with alpha flattened onto opaque
  white, a codec allow-list + duration cap for video, all via ffmpeg. Byte-size caps and min/max
  pixel dimensions are **admin-configurable** (`Media.Limits`). Objects are stored id-keyed and
  opaque (physical path never stored), served only via an authorized, IDOR-hidden `GET /media/:id`
  (`Range`, hardened headers), with a daily **orphan janitor** reclaiming stray/staged objects.
  Uploads are rate-limited. New CI/deploy dependency: ffmpeg on `PATH`.
- **Profile-image avatars for users & pets (ADR-0020)** — optional round-masked avatars reusing
  the same purify/storage/limits primitives (images only, separate keyspace). A user avatar is
  self-only and visible to any authenticated user; a pet avatar needs `:manage` and is
  `:read`-gated & IDOR-hidden. Uploads offer a **client-side square crop** applied
  authoritatively server-side in the same re-encode.

#### Medications

- **Medication schedules, doses & reminders (ADR-0019)** — recurring **schedules** (each with its
  own IANA timezone) materialize durable **dose slots** (wall-clock → UTC, idempotent). Marking a
  dose given is an atomic `pending → given` claim (TOCTOU-safe) that writes a normal `medication`
  timeline entry — one history, no parallel log. An Oban cron (`ReminderWorker`, `*/15`) fills the
  horizon, ages overdue slots to `missed`, and fans out a de-duped `medication_due` bell + Web
  Push to effective `:write` caretakers. Managed on `PetLive.Medications`.

#### Vet access & health reports

- **Vet access model — verified profiles & health reports (ADR-0012)** — the `vet` role is
  grantable only to a user with a **verified** `VetProfile` (submitted on `/users/vet-profile`,
  reviewed in the admin queue). `Reports.generate_report/3` freezes a shareable `jsonb` snapshot
  over a date range that **excludes every `private` entry**, with an optional expiring share link
  (only the token's SHA-256 hash stored). Vets author authoritative `vet_note` entries via a
  role-gated QuickLog path.

#### Notifications & messaging

- **In-site bell feed + private 1:1 mailbox (ADR-0011)** — per-recipient notification rows keyed
  by `type` (copy rendered at read time), covering grants/revokes, added logs (respecting
  visibility), medication reminders, media failures, and admin announcements (fanned out via
  Oban). A private mailbox allows 1:1 conversations, gated to users who share a pet, with
  read cursors and soft-deleted messages. Live nav unread badges via a global `on_mount` hook.
- **Web Push delivery + admin-managed VAPID (ADR-0011 Stage 2)** — every bell row (and each new
  mailbox message) can deliver a Web Push, hand-rolling RFC 8291/8188/8292 on `:crypto`. The
  outbound client is **SSRF-safe and DNS-pinned** (private-range denylist incl. IPv4-mapped /
  NAT64); browsers subscribe via a CSRF- and rate-limited endpoint. VAPID keys are managed on
  `/admin/settings`.

#### Accounts & authentication

- **Two-factor authentication — TOTP + WebAuthn (ADR-0013)** — opt-in for everyone, **required for
  the administrator**. TOTP (via `nimble_totp`/`eqrcode`) with single-use HMAC-hashed recovery
  codes and single-window replay rejection; FIDO2 security keys (via `wax_`/`cbor`) with
  sign-count regression enforcement. Primary auth (password *and* magic-link) routes through a
  pending-2FA challenge stage that issues no session token until a factor is re-verified
  server-side; secrets are encrypted / recovery codes hashed at rest.
- **Registration hardening (ADR-0016)** — per-address sliding-window rate limits on registration
  and magic-link emails, existence-hidden registration (no account-enumeration oracle), and a
  **single-administrator** database constraint.
- **Isolated, gated change-password** — password change is separated from the settings form and
  re-verifies the current password (and sudo mode).

#### Platform & operations

- **Timezone display/input policy (ADR-0018)** — times are stored UTC and resolved to an **active
  zone per viewer** (user preference → admin system default → `Etc/UTC`), process-scoped like the
  Gettext locale. Display shifts UTC → local; every `datetime-local` input (log `occurred_at`,
  end-of-care `ended_at`, grant `expires_at`) converts wall-clock → UTC before the changeset and
  prefills back to local, via the shared `Helpers.put_local_datetime/4` / `to_datetime_local/2`.
  Users pick a zone on `/users/settings` (browser-prefilled); an admin sets the system default.
  Backed by the pure-Elixir `tz` database.
- **Rust NIF native boundary (ADR-0017)** — a `Goodmao2.Native` Rustler crate
  (`native/goodmao2_native`) built by `mix compile`, toolchain pinned by `rust-toolchain.toml`.
  Proven scaffolding (currently a placeholder `add/2`) for future CPU-bound work.
- **Background jobs (Oban) + token janitor** — Postgres-backed Oban with `Oban.Plugins.Cron`; a
  daily `TokenJanitor` prunes expired auth tokens. Foundation for the media/reminder/fan-out/push
  workloads above.
- **Administrator surface (`/admin`, `/admin/settings`)** — an admin-only, IDOR-hidden site
  overview and vet-credential review queue, plus a settings page managing the Web Push VAPID
  keypair, the system default timezone, and the media upload limits. Administration is a global
  role that grants **no** pet-data access.
- **Production email via Amazon SES**, **`mix release` scaffolding**, a **co-hosting deployment
  runbook**, and an **Ansible playbook** for the deployment story.
- **CI / Dependabot / security tooling** — a GitHub Actions gate (compile with
  warnings-as-errors, format, unused-deps, `mix_audit`, `sobelow`, full test suite) against a
  Postgres service; weekly grouped Dependabot updates; the audit + scan also run in
  `mix precommit`.
- **`GET /health`** liveness/readiness probe, a per-request **nonce-based CSP**,
  **`mix goodmao.doctor`** environment preflight, a **locale-parity test**, and **dev HTTPS on
  `:4001`**.

#### i18n, UX & docs

- **Trilingual UI (en / 台灣漢語 / 日本語)** — per-request locale resolution (cookie →
  `Accept-Language` → default), a language switcher that persists the choice, `<html lang>`
  reflection, and a Gettext-backed brand wordmark (`GoodMao` / `顧毛` / `グッドマオ`, ADR-0002).
  The `zh_TW` / `ja_JP` catalogs are culturally localized, and every feature above ships localized.
- **Larger default text + a font-size control** (20px base, −/+ control, persisted, applied
  pre-paint), **Roboto Slab as the general alphanumeric font with a CJK-aware fallback chain**,
  and a **localized page title on every route** (WCAG 2.4.2).
- **Accessibility & UX polish** — skip-to-content link, `:focus-visible` brand ring,
  `aria-hidden` decorative icons, a global `prefers-reduced-motion` guard, elevation/motion design
  tokens, a `theme-color` meta + inline SVG favicon, a sticky app-shell + footer, and the
  **`a11y-engineering`** Claude skill.
- **Project documentation** — glossary, ADRs (0004–0020), a common-practices reference, and
  expanded roadmap sections; the **"Terracotta + Teal"** brand as WCAG-verified daisyUI
  light/dark themes.
- **License — AGPL-3.0-or-later** — the full `LICENSE` text, a README License section (with the
  vendored Roboto Slab staying under Apache-2.0), and a `licenses:` entry in `mix.exs`.

### Changed

- **Responsive primary navigation** — the header collapses into a hamburger disclosure on small
  screens (CSP-safe `<details>`, no added JS) and stays an inline bar at `lg`+.
- **Language switcher moved to the footer** — the locale chooser opens upward from the page foot,
  decluttering the top bar.
- **Past pets moved off the active list** — ended companions have their own quiet memorial surface
  at `/pets/past`, reached by a subtle link from Account settings rather than the everyday list
  (ADR-0003), and are shown in a muted, graceful tone rather than warning-amber.
- **Species enum expanded** to the full set of companion animals.
- **Clock-skew tolerance** — `occurred_at` / `ended_at` future-guards allow a 5-minute skew.
- Hard-fenced `priv/repo/seeds.exs` to `:dev` so demo accounts can never be planted in
  staging/production.

### Fixed

- **Timezone consistency for datetime-local inputs** — end-of-care `ended_at` and grant
  `expires_at` now interpret the entered wall-clock in the viewer's zone and store UTC (and
  prefill back to local), matching the log forms, instead of storing the browser value as if UTC.
- Re-stream the notifications feed and messages inbox on live updates; keep the avatar uploader
  popover open across re-renders; wrap the pet-actions nav so it doesn't overflow on mobile;
  harden avatar-crop accessibility and robustness; and a sweep of security-audit minor findings.

### Security

- **Enforced modeled-but-unenforced authorization/visibility rules** (parity audit):
  `history_hidden` on every log read/write, per-entry `private` visibility on reads and the live
  timeline, recorder-or-owner scoping on log edit/delete, the ≥1-owner invariant on the
  grant-update path with a `FOR UPDATE` row lock, an optional site-owner gate on the bootstrap
  administrator, and stricter `@handle` rules.
- **Registration hardening (ADR-0016)** — per-address rate limits, existence-hidden registration,
  and the single-administrator database constraint.
- **Secret handling** — the Web Push VAPID private key and 2FA TOTP secrets are AES-256-GCM
  encrypted at rest (keyed off `SECRET_KEY_BASE`), recovery codes are HMAC-hashed, and the Web
  Push outbound client is SSRF-safe and DNS-pinned.

## [0.1.0] - 2026-07-18

Initial GoodMao baseline — the Phoenix/LiveView MVP core: scope-based
authentication with a public `@handle`, pets with an end-of-care lifecycle, resource-based
per-pet authorization, structured one-table log entries, and a live, filterable timeline
over Phoenix PubSub. Trilingual Gettext scaffolding (`en` / `zh_TW` / `ja_JP`) and the
`mix precommit` gate.
