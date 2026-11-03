// LiveView hook for Web Push subscription management (ADR-0011 Stage 2).
// Registers the service worker, requests permission via pushManager.subscribe, and
// POSTs/DELETEs the subscription to /api/push-subscriptions with the CSRF token.

import { urlBase64ToUint8Array, arrayBufferToBase64Url } from "./base64url.js"

const PushManager = {
  mounted() {
    this.vapidKey = document.querySelector('meta[name="vapid-public-key"]')?.content

    if (!this.vapidKey || !("serviceWorker" in navigator) || !("PushManager" in window)) {
      this.pushEvent("push_support", { supported: false, subscribed: false })
      return
    }

    navigator.serviceWorker
      .register("/service_worker.js", { scope: "/" })
      .then((registration) => {
        this.registration = registration
        return registration.pushManager.getSubscription()
      })
      .then((subscription) => this.verify(subscription))
      .then((subscribed) => this.pushEvent("push_support", { supported: true, subscribed }))
      .catch(() => this.pushEvent("push_support", { supported: false, subscribed: false }))

    this.el.addEventListener("push:subscribe", () => this.subscribe())
    this.el.addEventListener("push:unsubscribe", () => this.unsubscribe())
  },

  // The browser's subscription outlives a log-out and a change of user on this profile, so
  // ask the server whether it is a live subscription of the *current* user. A definite "no"
  // (404) drops the browser's copy, so the page offers to enable push instead of claiming it
  // is on; any other failure trusts the browser rather than discard a working subscription.
  verify(subscription) {
    if (!subscription) return Promise.resolve(false)

    return fetch("/api/push-subscriptions/status", {
      method: "POST",
      headers: { "Content-Type": "application/json", "x-csrf-token": this.csrf() },
      body: JSON.stringify({ endpoint: subscription.endpoint }),
    }).then((response) => {
      if (response.status === 404) {
        return subscription
          .unsubscribe()
          .catch(() => {})
          .then(() => false)
      }
      return true
    }, () => true)
  },

  csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  },

  subscribe() {
    if (!this.registration) return
    const applicationServerKey = urlBase64ToUint8Array(this.vapidKey)

    this.registration.pushManager
      .subscribe({ userVisibleOnly: true, applicationServerKey })
      .then((subscription) =>
        fetch("/api/push-subscriptions", {
          method: "POST",
          headers: { "Content-Type": "application/json", "x-csrf-token": this.csrf() },
          body: JSON.stringify({
            endpoint: subscription.endpoint,
            p256dh: arrayBufferToBase64Url(subscription.getKey("p256dh")),
            auth: arrayBufferToBase64Url(subscription.getKey("auth")),
            user_agent: navigator.userAgent,
          }),
        }).then((response) => {
          if (response.ok) return this.pushEvent("push_subscribed", {})
          // The server stored nothing: drop the browser's half too, or the next visit would
          // read it as "push is on" while no push ever arrives.
          return subscription
            .unsubscribe()
            .catch(() => {})
            .then(() => this.pushEvent("push_subscribe_error", { reason: "server_error" }))
        })
      )
      .catch((err) => {
        if (err.name === "NotAllowedError") this.pushEvent("push_permission_denied", {})
        else this.pushEvent("push_subscribe_error", { reason: err.message || "unknown" })
      })
  },

  unsubscribe() {
    if (!this.registration) return

    this.registration.pushManager
      .getSubscription()
      .then((subscription) => {
        if (!subscription) return
        const endpoint = subscription.endpoint
        return subscription.unsubscribe().then(() =>
          fetch("/api/push-subscriptions", {
            method: "DELETE",
            headers: { "Content-Type": "application/json", "x-csrf-token": this.csrf() },
            body: JSON.stringify({ endpoint }),
          })
        )
      })
      .then(() => this.pushEvent("push_unsubscribed", {}))
      .catch(() => this.pushEvent("push_subscribe_error", { reason: "unsubscribe_failed" }))
  },
}

export default PushManager
