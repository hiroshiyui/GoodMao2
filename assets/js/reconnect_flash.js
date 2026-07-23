// Graceful reconnect banners.
//
// LiveView stamps `phx-client-error` / `phx-server-error` on <html> the moment the socket
// drops, and the stock wiring reveals a red "Attempting to reconnect" flash immediately.
// That is right for a real outage and wrong for the common case on a phone: locking the
// screen or switching apps suspends the socket, so returning to the installed PWA greeted
// the user with a scary error that vanished a moment later.
//
// So watch the same classes here and hold the banner back through a short grace period.
// A disconnect that heals inside the window is never shown; a real one still surfaces,
// only a beat later. Hiding stays immediate -- the good news should never be delayed.
const GRACE_MS = 2000

const BANNERS = [
  {id: "client-error", className: "phx-client-error"},
  {id: "server-error", className: "phx-server-error"},
]

const setVisible = (id, visible) => {
  const el = document.getElementById(id)
  if (!el) return

  if (visible) {
    el.removeAttribute("hidden")
    el.style.display = ""
  } else {
    el.setAttribute("hidden", "")
    el.style.display = "none"
  }
}

export default function initReconnectFlash() {
  let timer = null

  const disconnected = () =>
    BANNERS.some(({className}) => document.documentElement.classList.contains(className))

  const observer = new MutationObserver(() => {
    if (disconnected()) {
      // Keep the first timer running: re-arming it on every class change would push the
      // deadline back indefinitely while the socket retries, and the banner would never show.
      if (timer) return

      timer = setTimeout(() => {
        timer = null
        // Re-check on expiry rather than trusting the state that armed the timer -- the
        // socket may have recovered and dropped again as a different error in between.
        BANNERS.forEach(({id, className}) => {
          setVisible(id, document.documentElement.classList.contains(className))
        })
      }, GRACE_MS)
    } else {
      if (timer) {
        clearTimeout(timer)
        timer = null
      }
      BANNERS.forEach(({id}) => setVisible(id, false))
    }
  })

  observer.observe(document.documentElement, {attributes: true, attributeFilter: ["class"]})
}
