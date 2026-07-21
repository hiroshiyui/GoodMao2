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

// Network-first passthrough — needed for PWA installability on some browsers.
self.addEventListener("fetch", (event) => {
  event.respondWith(fetch(event.request))
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
