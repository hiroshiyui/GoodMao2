// GoodMao service worker: Web Push display + click routing (ADR-0011 Stage 2).
// Bundled separately by esbuild and served from the site root so its scope is "/".

function isSameOrigin(url) {
  try {
    return new URL(url, self.location.origin).origin === self.location.origin
  } catch {
    return false
  }
}

self.addEventListener("push", (event) => {
  if (!event.data) return

  let data
  try {
    data = event.data.json()
  } catch {
    data = { title: "GoodMao", body: event.data.text() }
  }

  const options = {
    body: data.body || "",
    data: { url: data.url || "/" },
    tag: data.type || "default",
    renotify: true,
  }
  // Only set an icon/badge when the payload carries one — GoodMao's favicon is an inline
  // SVG data URI with no served file, so there is no default path to point at.
  if (data.icon) {
    options.icon = data.icon
    options.badge = data.icon
  }

  event.waitUntil(self.registration.showNotification(data.title || "GoodMao", options))
})

// Offline fallback. Chrome will not offer to install a PWA unless the service worker can
// answer a *navigation* while offline, so a bare `fetch()` passthrough is not enough — the
// one precached page is what makes the app installable.
//
// GoodMao's pages are all authenticated, per-viewer and live, so caching them would serve
// one user's data to whoever opens the app next. Nothing but this static shell is cached.
const CACHE = "goodmao-offline-v1"
const OFFLINE_URL = "/offline.html"

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.add(new Request(OFFLINE_URL, { cache: "reload" })))
      .then(() => self.skipWaiting())
  )
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  )
})

// Navigations only — everything else (assets, the LiveView socket, API calls) goes straight
// to the network untouched.
self.addEventListener("fetch", (event) => {
  if (event.request.mode !== "navigate") return

  event.respondWith(
    fetch(event.request).catch(() => caches.match(OFFLINE_URL, { cacheName: CACHE }))
  )
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()

  const rawUrl = event.notification.data?.url
  const url = rawUrl && isSameOrigin(rawUrl) ? rawUrl : "/"

  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((windowClients) => {
      for (const client of windowClients) {
        if (client.url === url && "focus" in client) return client.focus()
      }
      if (clients.openWindow) return clients.openWindow(url)
    })
  )
})
