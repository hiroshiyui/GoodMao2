// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/goodmao2"
import topbar from "../vendor/topbar"
import PushManager from "./push_manager_hook.js"
import WebAuthn from "./webauthn_hook.js"
import TimezoneDetect from "./timezone_detect.js"

// Reveal pointer-glow: track the cursor over an element marked phx-hook="PointerGlow"
// (paired with the .gm-glow CSS) and expose its position as CSS custom properties.
// Self-disables when the user prefers reduced motion — the listener is never attached.
const PointerGlow = {
  mounted() {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
    this.onMove = (e) => {
      const rect = this.el.getBoundingClientRect()
      this.el.style.setProperty("--gm-glow-x", `${e.clientX - rect.left}px`)
      this.el.style.setProperty("--gm-glow-y", `${e.clientY - rect.top}px`)
    }
    this.el.addEventListener("pointermove", this.onMove)
  },
  destroyed() {
    if (this.onMove) this.el.removeEventListener("pointermove", this.onMove)
  },
}

// Print: a CSP-safe way to trigger the browser print dialog from a button (inline
// onclick handlers are blocked by the Content-Security-Policy). Used by the report page.
const Print = {
  mounted() {
    this.onClick = () => window.print()
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
  },
}

// Font-size zoom: persist the root font-size (as a percentage) in localStorage and
// apply it to <html>. The whole UI is rem-based, so this scales everything. The
// default (125% = 20px) matches the CSS baseline in app.css; the pre-paint guard
// in root.html.heex applies any stored value before first paint to avoid a flash.
const FONT_SIZE_KEY = "phx:font-size"
const FONT_SIZE_DEFAULT = 125
const FONT_SIZE_MIN = 100
const FONT_SIZE_MAX = 175
const FONT_SIZE_STEP = 12.5
const clampFontSize = (size) =>
  Math.max(FONT_SIZE_MIN, Math.min(FONT_SIZE_MAX, Number(size) || FONT_SIZE_DEFAULT))
// Apply the size WITHOUT persisting it — so the default is never frozen into
// localStorage. Only an explicit −/+ choice (setFontSize) is stored; that way a
// later change to FONT_SIZE_DEFAULT reaches everyone who hasn't picked a size.
const applyFontSize = (size) => {
  document.documentElement.style.fontSize = clampFontSize(size) + "%"
}
const setFontSize = (size) => {
  const s = clampFontSize(size)
  localStorage.setItem(FONT_SIZE_KEY, String(s))
  applyFontSize(s)
}
applyFontSize(localStorage.getItem(FONT_SIZE_KEY) || FONT_SIZE_DEFAULT)
window.addEventListener("phx:font-size-increase", () => {
  setFontSize((Number(localStorage.getItem(FONT_SIZE_KEY)) || FONT_SIZE_DEFAULT) + FONT_SIZE_STEP)
})
window.addEventListener("phx:font-size-decrease", () => {
  setFontSize((Number(localStorage.getItem(FONT_SIZE_KEY)) || FONT_SIZE_DEFAULT) - FONT_SIZE_STEP)
})
window.addEventListener("storage", (e) => {
  if (e.key === FONT_SIZE_KEY) applyFontSize(e.newValue || FONT_SIZE_DEFAULT)
})

// After the pet timeline pages (server pushes this once the new slice is rendered), bring the
// top of the timeline section into view so a paged list doesn't leave the viewport mid-scroll.
// Honor prefers-reduced-motion (jump instead of animating), matching the app's motion guard.
window.addEventListener("phx:scroll-to-timeline", () => {
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches
  document.getElementById("timeline-section")?.scrollIntoView({
    behavior: reduce ? "auto" : "smooth",
    block: "start",
  })
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, PointerGlow, Print, PushManager, WebAuthn, TimezoneDetect},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

