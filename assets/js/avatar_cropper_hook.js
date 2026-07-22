// AvatarCropper — a tiny, dependency-free square crop selector for avatar uploads (ADR-0020).
//
// The hook element (phx-update="ignore") holds four server-rendered hidden inputs
// (crop[x], crop[y], crop[w], crop[h]). When a file is chosen in the form's file input, we
// preview it (via a FileReader *data* URL — CSP allows `img-src data:`, not `blob:`) inside a
// fixed square viewport and overlay a draggable/resizable **square** box. On every change we
// write the box as normalized fractions of the natural image into the hidden inputs; the form
// submit ships them and the server performs the real crop in the ffmpeg purify step.
//
// Coordinates: because the preview keeps aspect ratio, a square on-screen box maps to a square
// pixel crop, so we only ever report x/y/w/h ∈ [0,1] and never touch pixels here.

const VIEWPORT = 224 // px — the square preview area
const MIN_BOX = 32 // px — smallest selectable square on screen

const AvatarCropper = {
  mounted() {
    this.form = this.el.closest("form")
    this.fileInput = this.form && this.form.querySelector('input[type="file"]')
    this.inputs = {
      x: this.el.querySelector('input[name="crop[x]"]'),
      y: this.el.querySelector('input[name="crop[y]"]'),
      w: this.el.querySelector('input[name="crop[w]"]'),
      h: this.el.querySelector('input[name="crop[h]"]'),
    }

    this.hint = this.el.querySelector(".avatar-cropper-hint")
    this.buildDom()

    if (this.fileInput) {
      this.onChange = () => this.loadSelectedFile()
      this.fileInput.addEventListener("change", this.onChange)
    }
  },

  destroyed() {
    if (this.fileInput && this.onChange) {
      this.fileInput.removeEventListener("change", this.onChange)
    }
    // The popover (and this hook) is added/removed from the DOM on every open/close, so the
    // window-level pointer listeners MUST be detached here or they accumulate for the session.
    if (this._onMove) window.removeEventListener("pointermove", this._onMove)
    if (this._onUp) window.removeEventListener("pointerup", this._onUp)
  },

  buildDom() {
    const wrap = document.createElement("div")
    wrap.className =
      "avatar-cropper-viewport relative mx-auto mt-2 hidden overflow-hidden rounded-box border border-base-300 bg-base-200"
    wrap.style.width = VIEWPORT + "px"
    wrap.style.height = VIEWPORT + "px"
    wrap.style.touchAction = "none"

    const img = document.createElement("img")
    img.className = "pointer-events-none absolute select-none"
    img.alt = ""

    const box = document.createElement("div")
    box.className =
      "avatar-crop-box absolute cursor-move rounded-full border-2 border-white shadow-[0_0_0_9999px_rgba(0,0,0,0.45)]"
    // Keyboard-operable (WCAG 2.1.1): focusable, announced, driven by arrow keys / +-/ below.
    box.tabIndex = 0
    box.setAttribute("role", "slider")
    const label = this.el.getAttribute("data-crop-label")
    if (label) box.setAttribute("aria-label", label)

    const handle = document.createElement("div")
    handle.className =
      "avatar-crop-handle absolute -right-1 -bottom-1 size-4 cursor-nwse-resize rounded-full border-2 border-white bg-primary"
    box.appendChild(handle)

    wrap.appendChild(img)
    wrap.appendChild(box)
    this.el.appendChild(wrap)

    this.wrap = wrap
    this.img = img
    this.box = box
    this.handle = handle

    this.wireDragging()
  },

  loadSelectedFile() {
    const file = this.fileInput.files && this.fileInput.files[0]
    if (!file) {
      this.wrap.classList.add("hidden")
      if (this.hint) this.hint.classList.add("hidden")
      this.clearInputs()
      return
    }

    const reader = new FileReader()
    reader.onload = () => {
      const probe = new Image()
      probe.onload = () => this.showImage(probe.naturalWidth, probe.naturalHeight, reader.result)
      probe.src = reader.result
    }
    reader.readAsDataURL(file)
  },

  showImage(nw, nh, dataUrl) {
    if (!nw || !nh) return

    const scale = Math.min(VIEWPORT / nw, VIEWPORT / nh)
    this.rendered = { w: nw * scale, h: nh * scale }
    this.rendered.left = (VIEWPORT - this.rendered.w) / 2
    this.rendered.top = (VIEWPORT - this.rendered.h) / 2

    this.img.src = dataUrl
    this.img.style.left = this.rendered.left + "px"
    this.img.style.top = this.rendered.top + "px"
    this.img.style.width = this.rendered.w + "px"
    this.img.style.height = this.rendered.h + "px"

    // Default to the largest centered square.
    const side = Math.min(this.rendered.w, this.rendered.h)
    this.boxRect = {
      left: this.rendered.left + (this.rendered.w - side) / 2,
      top: this.rendered.top + (this.rendered.h - side) / 2,
      size: side,
    }
    this.applyBox()
    this.wrap.classList.remove("hidden")
    if (this.hint) this.hint.classList.remove("hidden")
  },

  wireDragging() {
    let mode = null // "move" | "resize"
    let startX = 0
    let startY = 0
    let start = null

    const onDown = (e, m) => {
      if (!this.boxRect) return
      mode = m
      startX = e.clientX
      startY = e.clientY
      start = { ...this.boxRect }
      e.target.setPointerCapture(e.pointerId)
      e.preventDefault()
      e.stopPropagation()
    }

    const onMove = (e) => {
      if (!mode) return
      const dx = e.clientX - startX
      const dy = e.clientY - startY
      const r = this.rendered
      const imgRight = r.left + r.w
      const imgBottom = r.top + r.h

      if (mode === "move") {
        let left = start.left + dx
        let top = start.top + dy
        left = Math.max(r.left, Math.min(left, imgRight - start.size))
        top = Math.max(r.top, Math.min(top, imgBottom - start.size))
        this.boxRect = { left, top, size: start.size }
      } else {
        const maxSize = Math.min(imgRight - start.left, imgBottom - start.top)
        let size = start.size + Math.max(dx, dy)
        size = Math.max(MIN_BOX, Math.min(size, maxSize))
        this.boxRect = { left: start.left, top: start.top, size }
      }
      this.applyBox()
    }

    const onUp = () => {
      mode = null
    }

    this.box.addEventListener("pointerdown", (e) => {
      if (e.target === this.handle) onDown(e, "resize")
      else onDown(e, "move")
    })

    // Keyboard path: arrows move, +/- resize. Element-scoped, so it's cleaned up with the box.
    this.box.addEventListener("keydown", (e) => this.onKey(e))

    window.addEventListener("pointermove", onMove)
    window.addEventListener("pointerup", onUp)

    // Remember the window listeners so destroyed() detaches them (the hook is re-mounted on
    // every popover open, so leaving them attached would leak a pair per open).
    this._onMove = onMove
    this._onUp = onUp
  },

  onKey(e) {
    if (!this.boxRect || !this.rendered) return
    const STEP = 4 // px per arrow key
    const RESIZE = 8 // px per +/-
    let { left, top, size } = this.boxRect

    switch (e.key) {
      case "ArrowLeft":
        left -= STEP
        break
      case "ArrowRight":
        left += STEP
        break
      case "ArrowUp":
        top -= STEP
        break
      case "ArrowDown":
        top += STEP
        break
      case "+":
      case "=":
        size += RESIZE
        break
      case "-":
      case "_":
        size -= RESIZE
        break
      default:
        return
    }
    e.preventDefault()

    const r = this.rendered
    size = Math.max(MIN_BOX, Math.min(size, Math.min(r.w, r.h)))
    left = Math.max(r.left, Math.min(left, r.left + r.w - size))
    top = Math.max(r.top, Math.min(top, r.top + r.h - size))
    this.boxRect = { left, top, size }
    this.applyBox()
  },

  applyBox() {
    const b = this.boxRect
    this.box.style.left = b.left + "px"
    this.box.style.top = b.top + "px"
    this.box.style.width = b.size + "px"
    this.box.style.height = b.size + "px"
    this.writeInputs()
  },

  writeInputs() {
    const r = this.rendered
    const b = this.boxRect
    this.setInput("x", (b.left - r.left) / r.w)
    this.setInput("y", (b.top - r.top) / r.h)
    this.setInput("w", b.size / r.w)
    this.setInput("h", b.size / r.h)
  },

  setInput(key, value) {
    if (this.inputs[key]) this.inputs[key].value = Math.max(0, Math.min(1, value)).toFixed(6)
  },

  clearInputs() {
    ;["x", "y", "w", "h"].forEach((k) => this.inputs[k] && (this.inputs[k].value = ""))
  },
}

export default AvatarCropper
