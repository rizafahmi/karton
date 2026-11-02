const NOTICE_DURATION = 5000

const CanvasMessages = {
  mounted() {
    this.nativePopover = "popover" in HTMLElement.prototype &&
      typeof this.el.showPopover === "function" && typeof this.el.hidePopover === "function"
    this.notice = null
    this.focusRequest = null
    this.focusBeforePatch = null

    this.onNoticeInteraction = () => this.updateNoticeTimer()
    this.onFocusOut = () => {
      // focusout fires before the next control becomes document.activeElement.
      clearTimeout(this.focusTimer)
      this.focusTimer = setTimeout(() => this.updateNoticeTimer(), 0)
    }
    this.onFeedbackClick = event => {
      const status = event.target.closest("button#save-status")
      if (status && status.getAttribute("aria-controls") === this.el.id && event.detail === 0) {
        this.focusRequest = {trigger: status, generation: this.el.dataset.generation}
      }
      const dismiss = event.target.closest(".message-dismiss")
      if (dismiss && this.el.contains(dismiss) && dismiss === document.activeElement) {
        this.returnFocus()
      }
    }
    document.addEventListener("click", this.onFeedbackClick, true)
    this.el.addEventListener("focusin", this.onNoticeInteraction)
    this.el.addEventListener("focusout", this.onFocusOut)
    this.syncFeedback()
  },

  beforeUpdate() {
    const active = document.activeElement
    this.focusBeforePatch = this.el.contains(active) ? active : null
  },

  updated() {
    this.syncFeedback()
    const previous = this.focusBeforePatch
    this.focusBeforePatch = null
    if (previous && (!previous.isConnected || previous.closest(".canvas-message")?.hidden) &&
      (document.activeElement === document.body || document.activeElement === previous)) {
      this.returnFocus()
    }

    const request = this.focusRequest
    if (!request) return
    this.focusRequest = null
    if (request.generation !== this.el.dataset.generation) return
    const active = document.activeElement
    if (active !== request.trigger && active !== document.body) return
    const dismiss = this.el.querySelector(
      "#file-error:not([hidden]) .message-dismiss, #disk-warning:not([hidden]) .message-dismiss"
    )
    if (dismiss) dismiss.focus({preventScroll: true})
    else this.focusRequest = request
  },

  syncFeedback() {
    const visible = this.el.querySelector(".canvas-message:not([hidden])") !== null
    if (visible) this.el.hidden = false
    if (this.nativePopover) {
      const open = this.el.matches(":popover-open")
      if (visible && !open) this.el.showPopover()
      if (!visible && open) this.el.hidePopover()
    } else {
      // LiveView may restore this attribute on any patch.
      this.el.removeAttribute("popover")
    }
    this.el.hidden = !visible

    const element = this.el.querySelector("#file-notice:not([hidden])")
    const id = element?.dataset.noticeId
    const generation = this.el.dataset.generation
    if (!element || !id) {
      this.clearNotice()
      return
    }
    if (this.notice?.id !== id || this.notice?.generation !== generation) {
      this.clearNotice()
      this.notice = {id, generation, element, remaining: NOTICE_DURATION, timer: null, sent: false}
      this.bindNotice(element)
    } else if (this.notice.element !== element) {
      this.pauseNotice()
      this.unbindNotice()
      this.notice.element = element
      this.bindNotice(element)
    }
    this.updateNoticeTimer()
  },

  bindNotice(element) {
    element.addEventListener("mouseenter", this.onNoticeInteraction)
    element.addEventListener("mouseleave", this.onNoticeInteraction)
  },

  unbindNotice() {
    this.notice?.element.removeEventListener("mouseenter", this.onNoticeInteraction)
    this.notice?.element.removeEventListener("mouseleave", this.onNoticeInteraction)
  },

  pauseNotice() {
    const notice = this.notice
    if (notice?.timer === null || !notice) return
    clearTimeout(notice.timer)
    notice.timer = null
    notice.remaining = Math.max(0, notice.remaining - (performance.now() - notice.started))
  },

  updateNoticeTimer() {
    const notice = this.notice
    if (!notice || notice.sent) return
    if (notice.element.matches(":hover") || notice.element.contains(document.activeElement)) {
      this.pauseNotice()
      return
    }
    if (notice.timer !== null) return
    notice.started = performance.now()
    notice.timer = setTimeout(() => {
      notice.timer = null
      notice.remaining = 0
      // Check identity and focus again at expiry, not just when scheduling.
      if (this.notice !== notice || notice.generation !== this.el.dataset.generation ||
        notice.element.dataset.noticeId !== notice.id || !notice.element.isConnected) return
      if (notice.element.matches(":hover") || notice.element.contains(document.activeElement)) return
      notice.sent = true
      this.pushEvent("dismiss-feedback", {kind: "notice", id: notice.id, generation: notice.generation})
    }, notice.remaining)
  },

  clearNotice() {
    clearTimeout(this.focusTimer)
    this.pauseNotice()
    this.unbindNotice()
    this.notice = null
  },

  returnFocus() {
    const status = document.querySelector("button#save-status")
    const target = status || document.getElementById("save-file")
    target?.focus({preventScroll: true})
  },

  destroyed() {
    this.clearNotice()
    clearTimeout(this.focusTimer)
    document.removeEventListener("click", this.onFeedbackClick, true)
    this.el.removeEventListener("focusin", this.onNoticeInteraction)
    this.el.removeEventListener("focusout", this.onFocusOut)
    if (this.nativePopover && this.el.matches(":popover-open")) this.el.hidePopover()
  },
}

export {CanvasMessages}
