// Preserve a <details> element's open/closed state across LiveView patches.
//
// `open` is DOM state the server render knows nothing about, so the rendered markup
// never carries the attribute. Any patch that reaches the element -- a phx-change echo
// from the form inside it, a PubSub timeline event -- therefore snaps the disclosure
// shut underneath the user, taking focus (and an in-flight IME composition) with it.
//
// Re-applying the remembered state after each update keeps the panel as the user left it.
const DisclosureState = {
  mounted() {
    this.wasOpen = this.el.open
    this.el.addEventListener("toggle", () => {
      this.wasOpen = this.el.open
    })
  },

  beforeUpdate() {
    this.wasOpen = this.el.open
  },

  updated() {
    if (this.el.open !== this.wasOpen) {
      this.el.open = this.wasOpen
    }
  },
}

export default DisclosureState
