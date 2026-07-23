// Preserve a <details> element's open/closed state across LiveView patches.
//
// `open` is DOM state the server render knows nothing about, so the rendered markup
// never carries the attribute. Any patch that reaches the element -- a phx-change echo
// from the form inside it, a PubSub timeline event, a live unread-badge update -- would
// otherwise snap the disclosure shut underneath the user, taking focus (and an in-flight
// IME composition) with it.
//
// Re-applying the remembered state after each update keeps the panel as the user left it.
//
// Add `data-close-on-navigate` for menus rather than panels: a dropdown should survive an
// unrelated patch, but tapping one of its own links must still dismiss it instead of
// leaving the menu hanging open over the newly navigated page.
const DisclosureState = {
  mounted() {
    this.wasOpen = this.el.open
    this.closeOnNavigate = this.el.hasAttribute("data-close-on-navigate")

    this.onToggle = () => {
      this.wasOpen = this.el.open
    }
    this.el.addEventListener("toggle", this.onToggle)

    if (this.closeOnNavigate) {
      // Only live navigation dismisses the menu. page-loading-start also fires for
      // ordinary events flagged phx-page-loading, which must not close it.
      this.onNavigate = ({detail}) => {
        if (detail && (detail.kind === "redirect" || detail.kind === "patch")) {
          this.wasOpen = false
          this.el.open = false
        }
      }
      window.addEventListener("phx:page-loading-start", this.onNavigate)
    }
  },

  beforeUpdate() {
    this.wasOpen = this.el.open
  },

  updated() {
    if (this.el.open !== this.wasOpen) {
      this.el.open = this.wasOpen
    }
  },

  destroyed() {
    this.el.removeEventListener("toggle", this.onToggle)
    if (this.onNavigate) {
      window.removeEventListener("phx:page-loading-start", this.onNavigate)
    }
  },
}

export default DisclosureState
