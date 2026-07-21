# 5. Purified media for life logs

- **Status:** Accepted _(shipped — images + video)_
- **Date:** 2026-07-10
- **Deciders:** GoodMao maintainers

> _Shipped. Purification uses **ffmpeg/ffprobe** (images decoded and re-encoded, videos
> probed against a codec allow-list + duration cap and remuxed) behind the `Goodmao2.Media`
> storage seam — `image`/`vix` was the original suggestion, but ffmpeg covers both images and
> video with no extra native library. Objects are stored by id under a configured
> `storage_dir` (fail-fast in prod) and served only through `GET /media/:id`. Purification now
> runs **off the request path** in `Media.PurifyWorker` (Oban): the upload is staged, the entry
> is created immediately, and each file is purified + attached in the background (the media
> appears live via PubSub; a failure sends the uploader a `media_failed` bell). A daily
> `Media.OrphanJanitor` cron reclaims stray storage objects and stale staged uploads. Share-token
> media serving also shipped with per-entry share links (ADR-0004). The image re-encode now
> **flattens away any alpha channel** (onto opaque white) so transparency can't conceal content,
> and the **byte-size caps + min/max pixel dimensions** are **admin-configurable at runtime**
> (`Media.Limits`, Settings-backed, `0` = unbounded; the image dimension floor ships at 640×480)
> for images and videos alike._

## Context

The `life` log subtype (`LogEntry` with `type: "life"`) lets caretakers share the
everyday, non-clinical moments of a pet's life as **photos and videos** (its caption
reuses the base `note`). GoodMao models the `life` type but stores no binary media yet:
there is no upload, no storage backend, no serving path, no size or content-type limits.

Media is the highest-risk surface we can add: file uploads invite content-type
spoofing, polyglot files, decompression bombs, path traversal, metadata leakage
(EXIF **GPS** on a pet photo can reveal the owner's home), and IDOR on the served
bytes. Security is GoodMao's overriding constraint, and the requirement is explicit:
**every uploaded byte must be actively purified, not merely validated.** The design must
also respect the existing resource-based authorization (effective grant → role,
IDOR-hidden `not_found`) and the per-entry `visibility` / share-token model of
[ADR-0004](0004-log-visibility.md).

## Decision

**We will store life-log photos/videos as purified, opaque objects behind a storage
seam, described by a relational `media_assets` table, created atomically with the log,
and served only through an authorized, grant-gated endpoint.** The requirements below are
binding regardless of the eventual storage backend (local filesystem first; an
S3-compatible object store is a later option behind the same seam).

- **Metadata table.** A `media_assets` row holds `id`, `log_entry_id` (FK → the life log,
  cascade delete), a **denormalized `pet_id`** (the authorization anchor), kind
  (image/video), the server-validated content type, byte size, uploader, and an optional
  caption. **The physical path/key is derived from the id and never stored** — so it is
  path-traversal-proof by construction.
- **Atomic create.** The upload purifies every file, writes the clean bytes, then inserts
  the life-log entry **and** all media rows in a single Ecto transaction. A DB failure
  removes the just-written objects. There is never an orphan log with no media, nor a log
  row referencing bytes that were never stored.
- **Purification (the core requirement).**
  - **Content type by magic bytes**, never the client's header or filename. Allow-list:
    JPEG/PNG/GIF/WEBP images, MP4/WEBM video. **SVG is rejected** (active-content XML).
  - **Images** are decoded and **re-encoded** (stripping all EXIF/GPS/IPTC/XMP/profiles);
    the stored bytes are the encoder's output, which also neutralizes polyglots, trailing
    payloads, and (with decode limits) decompression bombs. The re-encode also **flattens any
    alpha channel onto an opaque background** so a transparent region cannot smuggle hidden or
    deceptive pixels.
  - **Videos** are validated (codec allow-list, duration cap) then **remuxed** to strip
    all container metadata (incl. GPS) and non-A/V streams.
  - **Text** (caption/note) is trimmed, control-character-stripped, and length-capped.
  - **Byte-size caps and min/max pixel dimensions** (per kind, images *and* videos) are enforced
    against `Media.Limits` — resolved from the `Settings` store so an administrator can tune every
    bound at runtime from `/admin/settings` (`0` on either side = unbounded). Defaults: images
    ≤ 8 MB with a 640×480 floor, videos ≤ 16 MB; all other bounds ship unbounded.
- **Serving.** One authenticated endpoint resolves the asset by its own id, re-applies the
  **parent log's read authorization** (effective grant + ADR-0004 `visibility` + recorder
  + `history_hidden`), hides existence with `not_found`, and streams the bytes with
  `Range` support and hardened headers (`X-Content-Type-Options: nosniff`, a restrictive
  `Content-Security-Policy`, `Content-Disposition: inline`). **There is no `pet_id` in the
  URL to forge** — the row's `pet_id` is the anchor. Uploads always flow **through** the
  app; the browser is never handed a pre-signed upload URL (raw client bytes must never
  reach storage unpurified), and reads stay authorized per request (no pre-signed read
  URLs for private/vet-scoped media).
- **Rate-limit** uploads per user.

## Consequences

- No static-file surface and no anonymous read path: the IDOR/existence-hidden posture
  and the ADR-0004 visibility model extend cleanly to media bytes.
- Stored media is always canonicalized, metadata-free output — a pet photo cannot leak
  the owner's GPS location, and a polyglot/malformed upload cannot be stored verbatim.
- **New operational concern:** a writable, backed-up, quota-managed storage location
  outside any served path; startup should fail-fast if it is unconfigured.
- **New deploy/CI dependency:** the image/video processing toolchain (native libraries
  behind `image`/`vix`, plus a video muxer on `PATH`).
- Objects are **not transactional** with the database (the create path writes bytes
  before the commit and compensates on failure), so a crash can leave orphan *objects*
  (invisible, reclaimable) but never dangling rows. An orphan-object **janitor** (an Oban
  job) is a follow-up; deletes are **soft** ([ADR-0008](0008-soft-delete.md)) and keep the
  bytes, so reclamation belongs to that janitor.
- **Shipped since v1:** async purification (`Media.PurifyWorker`, staging + background attach),
  the orphan-object **janitor** (`Media.OrphanJanitor`, daily cron), and share-token media serving.
- **Follow-ups (not in v1):** "attach more media to an existing life
  log"; public **shared** media serving mirroring the ADR-0004 token route; antivirus
  scanning; async/background processing at scale (Oban); reusing the media pipeline for
  owner-uploaded pet avatars (today a bare URL string).

## Alternatives considered

- **Object storage with pre-signed URLs** — the scalable production choice, but a
  pre-signed URL hands the browser a direct, time-boxed link that **bypasses the grant/
  IDOR checks**, and it adds a cloud dependency and secrets. Deferred; the storage seam
  leaves room to add an S3 backend behind the same authorized endpoints later.
- **Bytes in PostgreSQL (`bytea`/large objects)** — keeps one transactional store, but
  bloats the DB and backups and complicates streaming/`Range`. Rejected.
- **Static serving / CDN** — fast, but breaks grant-based authorization and leaks
  existence. Rejected; media must flow through the authorized endpoint.
- **Storing media as-uploaded / metadata-only image strip** — cheaper, but leaves GPS
  atoms in videos and lets polyglots through. Rejected: the requirement is *active*
  purification (images re-encoded, videos remuxed).
