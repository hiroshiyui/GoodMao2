// TimezoneDetect: a convenience prefill for the preferred-timezone <select> on the user
// settings page (ADR-0018). When the field has no saved value yet, set it to the browser's
// detected IANA zone (if that zone is one of the offered options) so most users never have to
// pick manually. This only prefills the control — the user still saves the form, and the server
// re-validates the value against the tz database.
export default {
  mounted() {
    this.prefill()
  },
  prefill() {
    if (this.el.value) return
    let tz
    try {
      tz = Intl.DateTimeFormat().resolvedOptions().timeZone
    } catch (_e) {
      return
    }
    if (!tz) return
    const match = Array.from(this.el.options).some((o) => o.value === tz)
    if (match) {
      this.el.value = tz
      // Let LiveView's phx-change (validate_profile) see the prefilled value.
      this.el.dispatchEvent(new Event("input", {bubbles: true}))
    }
  },
}
