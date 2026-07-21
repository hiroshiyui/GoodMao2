// LiveView hook driving the WebAuthn/FIDO2 browser ceremonies (ADR-0013).
//
// The hook is attached to a <form phx-hook="WebAuthn">. The server pushes one of two
// events with the ceremony options (base64url-encoded fields):
//
//   * "webauthn_register"     → navigator.credentials.create
//   * "webauthn_authenticate" → navigator.credentials.get
//
// The result is delivered one of two ways, chosen by the event payload:
//
//   * no "callback"  → base64url-encode the result into the form's [data-webauthn]
//     hidden inputs and submit natively (the login challenge — a controller must set
//     the session cookie).
//   * "callback" set → pushEvent(callback, {...}) back to the LiveView (settings
//     enrollment — the user is already logged in, so we stay in the LiveView).

import { urlBase64ToUint8Array, arrayBufferToBase64Url } from "./base64url.js"

const WebAuthn = {
  mounted() {
    this.handleEvent("webauthn_register", (payload) => this.register(payload))
    this.handleEvent("webauthn_authenticate", (payload) => this.authenticate(payload))
  },

  fail(message) {
    this.pushEvent("webauthn_error", { message })
  },

  deliver(callback, fields) {
    if (callback) {
      this.pushEvent(callback, fields)
    } else {
      for (const [name, value] of Object.entries(fields)) {
        const input = this.el.querySelector(`[data-webauthn="${name}"]`)
        if (input) input.value = value
      }
      this.el.requestSubmit()
    }
  },

  register({ options, callback }) {
    if (!window.PublicKeyCredential) return this.fail("unsupported")
    const opts = JSON.parse(options)

    const publicKey = {
      ...opts,
      challenge: urlBase64ToUint8Array(opts.challenge),
      user: { ...opts.user, id: urlBase64ToUint8Array(opts.user.id) },
      excludeCredentials: (opts.excludeCredentials || []).map((c) => ({
        ...c,
        id: urlBase64ToUint8Array(c.id),
      })),
    }

    navigator.credentials
      .create({ publicKey })
      .then((cred) =>
        this.deliver(callback, {
          attestation_object: arrayBufferToBase64Url(cred.response.attestationObject),
          client_data_json: arrayBufferToBase64Url(cred.response.clientDataJSON),
        })
      )
      .catch((err) => this.fail(err.name || "error"))
  },

  authenticate({ options, callback }) {
    if (!window.PublicKeyCredential) return this.fail("unsupported")
    const opts = JSON.parse(options)

    const publicKey = {
      ...opts,
      challenge: urlBase64ToUint8Array(opts.challenge),
      allowCredentials: (opts.allowCredentials || []).map((c) => ({
        ...c,
        id: urlBase64ToUint8Array(c.id),
      })),
    }

    navigator.credentials
      .get({ publicKey })
      .then((cred) =>
        this.deliver(callback, {
          credential_id: arrayBufferToBase64Url(cred.rawId),
          authenticator_data: arrayBufferToBase64Url(cred.response.authenticatorData),
          client_data_json: arrayBufferToBase64Url(cred.response.clientDataJSON),
          signature: arrayBufferToBase64Url(cred.response.signature),
        })
      )
      .catch((err) => this.fail(err.name || "error"))
  },
}

export default WebAuthn
