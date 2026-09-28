/**
 * Copying to the clipboard, sharing through the platform sheet, and saying so.
 *
 * Ported from Baudrate's clipboard.js (bc74e8e5). The old GoodMao `Clipboard` hook returned
 * silently when `navigator.clipboard` was missing (any non-secure context), swallowed a denied
 * permission, and announced success nowhere — so a copy button could do nothing at all and
 * nobody would know. For the report share link, which is shown exactly once, that loses the
 * link. Here a copy *never* fails silently:
 *
 *   1. the async Clipboard API, when present;
 *   2. otherwise (or when it rejects) the legacy `execCommand("copy")` over an off-screen
 *      textarea, which still works in insecure contexts and older WebViews;
 *   3. and when both fail, the source field is focused and selected so the text is one
 *      keystroke away, and the status says so.
 *
 * Every outcome is written to a `role="status"` region — the element named by
 * `data-clipboard-status` (server-rendered, visible, `phx-update="ignore"`), else a shared
 * sr-only region created on first use — and a success briefly marks the button itself.
 *
 * Labels are server-rendered gettext strings in `data-*` attributes; when one is missing
 * nothing is announced. The client never falls back to English.
 *
 * Element attributes (both hooks):
 *   - `data-clipboard-target` — selector for an <input>/<textarea> whose value to copy
 *   - `data-clipboard-text`   — literal text to copy (when there is no target)
 *   - `data-clipboard-status` — selector for the role="status" element to write into
 *   - `data-copied-label`     — announced after a successful copy
 *   - `data-copy-failed-label`— announced when neither copy path worked
 * WebShare only:
 *   - `data-share-url`, `data-share-title` — what to hand to `navigator.share`
 */

const ANNOUNCER_ID = "copy-announcer"
const FEEDBACK_MS = 2000

// Element → pending feedback timer, so repeated clicks restart rather than stack.
const feedback = new WeakMap()

function legacyCopy(text) {
  // execCommand needs a selection inside the document; build a throwaway, off-screen,
  // read-only textarea (read-only so a phone does not raise its keyboard).
  const area = document.createElement("textarea")
  area.value = text
  area.setAttribute("readonly", "")
  area.setAttribute("aria-hidden", "true")
  area.style.position = "fixed"
  area.style.top = "0"
  area.style.left = "-9999px"
  area.style.opacity = "0"
  const previous = document.activeElement
  document.body.appendChild(area)
  area.select()
  area.setSelectionRange(0, text.length)
  let ok = false
  try {
    ok = document.execCommand("copy")
  } catch {
    ok = false
  }
  area.remove()
  if (previous && typeof previous.focus === "function") previous.focus()
  return ok
}

/** Copies `text`. Resolves true on success, false on any failure; never throws or rejects. */
export async function copy(text) {
  if (!text) return false

  if (typeof navigator !== "undefined" && typeof navigator.clipboard?.writeText === "function") {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // Denied permission or an unfocused document — try the legacy path before giving up.
    }
  }

  return legacyCopy(text)
}

function announcerNode() {
  let node = document.getElementById(ANNOUNCER_ID)
  if (!node) {
    node = document.createElement("div")
    node.id = ANNOUNCER_ID
    node.className = "copy-announcer sr-only"
    node.setAttribute("role", "status")
    node.setAttribute("aria-live", "polite")
    node.setAttribute("aria-atomic", "true")
    document.body.appendChild(node)
  }
  return node
}

/** Writes `text` into the element's status region (or the shared one), re-announcing repeats. */
export function announce(el, text) {
  if (!text) return
  const sel = el.dataset.clipboardStatus
  const node = (sel && document.querySelector(sel)) || announcerNode()
  // Clear first so repeating the same message is announced again.
  node.textContent = ""
  setTimeout(() => {
    node.textContent = text
  }, 50)
}

function markCopied(el) {
  clearTimeout(feedback.get(el))
  el.setAttribute("data-copied", "true")
  el.classList.add("btn-success")
  feedback.set(
    el,
    setTimeout(() => {
      el.removeAttribute("data-copied")
      el.classList.remove("btn-success")
      feedback.delete(el)
    }, FEEDBACK_MS),
  )
}

function sourceField(el) {
  const sel = el.dataset.clipboardTarget
  return sel ? document.querySelector(sel) : null
}

function textFor(el) {
  const field = sourceField(el)
  return field ? field.value : el.dataset.clipboardText || el.dataset.shareUrl
}

/** Copies the element's text and reports the outcome either way. */
export async function copyAndReport(el) {
  const text = textFor(el)
  if (!text) return

  if (await copy(text)) {
    markCopied(el)
    announce(el, el.dataset.copiedLabel)
  } else {
    // Leave the text one keystroke away rather than nowhere.
    const field = sourceField(el)
    if (field) {
      field.focus()
      field.select()
    }
    announce(el, el.dataset.copyFailedLabel)
  }
}

function cancelFeedback(el) {
  clearTimeout(feedback.get(el))
  feedback.delete(el)
}

// Clipboard: copy a value from a button (CSP-safe — no inline handler).
export const Clipboard = {
  mounted() {
    this.onClick = (e) => {
      e.preventDefault()
      copyAndReport(this.el)
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    cancelFeedback(this.el)
  },
}

// WebShare: open the platform share sheet (phones, installed PWAs). The server renders the
// button `hidden`; it is revealed only where `navigator.share` exists, since the Copy button
// beside it already covers every other browser.
export const WebShare = {
  mounted() {
    if (typeof navigator === "undefined" || typeof navigator.share !== "function") return
    this.el.hidden = false

    this.onClick = async (e) => {
      e.preventDefault()
      const url = this.el.dataset.shareUrl
      if (!url) return
      const data = {url}
      if (this.el.dataset.shareTitle) data.title = this.el.dataset.shareTitle

      try {
        await navigator.share(data)
      } catch (err) {
        // Dismissing the sheet is the person saying no, not a failure: do nothing.
        if (err && err.name === "AbortError") return
        // The sheet could not open at all — copying is better than silence.
        copyAndReport(this.el)
      }
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
    cancelFeedback(this.el)
  },
}
