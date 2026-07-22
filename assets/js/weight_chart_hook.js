// Weight-chart datapoint tooltip: click a plotted point to toggle a small popup showing that
// day's date and average weight (data carried on each `.weight-point` circle as data-date /
// data-weight). Pure client-side — no server round-trip and CSP-safe (no inline handlers).
//
// The popup is a position:fixed element on <body>, positioned from the point's viewport rect and
// clamped to the viewport, so it is never clipped by the card/figure's `overflow: hidden` and
// never spills off-screen for edge points. Event delegation on the SVG means the listener
// survives LiveView re-renders that replace the inner circles (e.g. when a new weight is logged
// live). The SVG is aria-hidden; assistive tech reads the equivalent sr-only data table instead.
const MARGIN = 8

const WeightChart = {
  mounted() {
    this.tip = document.createElement("div")
    this.tip.className = "weight-tooltip"
    this.tip.hidden = true
    document.body.appendChild(this.tip)

    this.onClick = (e) => {
      const point = e.target.closest(".weight-point")
      if (point && this.el.contains(point)) {
        this.active === point ? this.hide() : this.show(point)
      } else {
        this.hide()
      }
    }
    this.onDismiss = (e) => {
      if (e.type === "keydown" && e.key !== "Escape") return
      this.hide()
    }

    document.addEventListener("click", this.onClick)
    document.addEventListener("keydown", this.onDismiss)
    // A fixed popup would otherwise float away from its point while the page scrolls.
    window.addEventListener("scroll", this.onDismiss, true)
    window.addEventListener("resize", this.onDismiss)
  },

  show(point) {
    const date = point.getAttribute("data-date") || ""
    const weight = point.getAttribute("data-weight") || ""
    this.tip.textContent = `${date} · ${weight}`
    this.tip.hidden = false // reveal first so it can be measured

    const dot = point.getBoundingClientRect()
    const vw = document.documentElement.clientWidth
    const half = this.tip.offsetWidth / 2

    // Centre on the point horizontally, clamped so the whole popup stays on-screen.
    const cx = Math.min(Math.max(dot.left + dot.width / 2, half + MARGIN), vw - half - MARGIN)

    // Sit above the point, but flip below when there isn't room above.
    const below = dot.top - MARGIN - this.tip.offsetHeight < 0
    this.tip.classList.toggle("weight-tooltip--below", below)

    this.tip.style.left = `${cx}px`
    this.tip.style.top = `${below ? dot.bottom + MARGIN : dot.top - MARGIN}px`
    this.active = point
  },

  hide() {
    this.tip.hidden = true
    this.active = null
  },

  destroyed() {
    document.removeEventListener("click", this.onClick)
    document.removeEventListener("keydown", this.onDismiss)
    window.removeEventListener("scroll", this.onDismiss, true)
    window.removeEventListener("resize", this.onDismiss)
    if (this.tip) this.tip.remove()
  },
}

export default WeightChart
