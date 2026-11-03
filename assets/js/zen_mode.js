const editors = '.hakushi-text-editor, .hakushi-edge-input, .drawing-thought-input'
const fields = 'input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"]'
const dialogs = 'dialog[open], [role="dialog"][aria-modal="true"]'
const hiddenChrome = '.document-identity, #save-file, #file-menu, #style-toggle, .style-inspector, .drawing-dock, .hakushi-controls, .hakushi-paper-menu, .hakushi-layout-menu, .zoom-popover, .hakushi-credit, .agentrouter-credit'

// Presentation belongs to this mounted workspace, not the file or native canvas.
export function mountZenMode(workspace) {
  const root = workspace.el
  let enabled = false, alive = true
  const hook = () => workspace.activeCanvas()
  const canvas = () => hook()?.fileCanvas
  const hasDocument = () => root.dataset.fileMode !== 'none' && !!hook()
  const ready = () => hasDocument() && hook().fileCanvasReady && !!canvas()
  const modalOwnsFocus = () => !!document.querySelector(dialogs)
  const live = element => element?.isConnected && canvas()?.root.contains(element)
  const editor = () => canvas()?.root.querySelector(editors)
  const canvasTarget = target => {
    const native = canvas()
    return !!native && native.root.contains(target) && (target === native.root || target.matches('.hakushi-node, .drawing-line-endpoint'))
  }

  function apply() {
    root.dataset.zenMode = String(enabled)
    for (const button of root.querySelectorAll('[data-zen-toggle]')) {
      button.setAttribute('aria-pressed', String(enabled))
      button.disabled = !enabled && !ready()
    }
  }

  function restoreFocus() {
    const native = canvas()
    if (!native || !hook().fileCanvasReady || modalOwnsFocus()) return
    const active = document.activeElement
    // Never take focus from a live editor, another visible control, or elsewhere.
    if (live(active) && !active.closest(hiddenChrome) && !active.closest('[data-zen-toggle]')) return
    if (active && active !== document.body && active.isConnected && !root.contains(active)) return
    const previous = native.lastFocus
    const target = editor() || (live(previous) && (canvasTarget(previous) || previous.matches(editors)) && !previous.closest(hiddenChrome) ? previous : native.root)
    if (active === target) return
    // Native focusIn selects/reveals nodes and clears direct keyboard edge focus.
    // Recover DOM focus only; keep those native editing states untouched.
    const retain = event => event.stopImmediatePropagation()
    target.addEventListener('focusin', retain, true)
    try {
      native.lastFocus = target
      target.focus({preventScroll: true})
    } finally {
      target.removeEventListener('focusin', retain, true)
    }
  }

  function dismissChrome() {
    const native = canvas()
    native?.togglePaperMenu(false)
    native?.toggleLayoutMenu(false)
    const zoom = root.querySelector('.zoom-popover:popover-open')
    zoom?.hidePopover?.()
    workspace.pushEvent('close-overlays', {})
  }

  function enter() {
    if (!alive || enabled || !ready() || modalOwnsFocus()) return false
    enabled = true
    apply()
    dismissChrome()
    restoreFocus()
    return true
  }

  function leave(refocus = true) {
    if (!alive || !enabled) return false
    enabled = false
    apply()
    if (refocus) restoreFocus()
    return true
  }

  const toggle = () => { if (enabled) leave(); else enter() }
  const exit = () => leave()
  const pointerDown = event => {
    if (!event.target.closest('[data-zen-toggle]') || event.button !== 0) return
    // A presentation button must not blur/commit inline text or cancel previews.
    if (live(document.activeElement) && (document.activeElement.closest(editors) || hook()?.directKeyboard?.active)) event.preventDefault()
  }
  const keyDown = event => {
    if (!alive || event.defaultPrevented || event.isComposing || event.keyCode === 229 || event.repeat || event.metaKey || event.ctrlKey || event.altKey) return
    const target = event.target
    if (!target?.closest || target.closest(`dialog, [role="dialog"], ${fields}`)) return
    if (event.shiftKey && event.key.toLowerCase() === 'z') {
      if (!canvasTarget(target) || modalOwnsFocus()) return
      if (enabled ? leave() : enter()) {
        event.preventDefault()
        event.stopImmediatePropagation()
      }
      return
    }
    if (event.key !== 'Escape' || event.shiftKey || !enabled || !root.contains(target)) return
    const native = canvas()
    // Let the original owner consume its first Escape, including when its
    // editor is mounted but the event originated on another canvas element.
    if (editor() || hook()?.directKeyboard?.active || native?.tool || native?.gesture || native?.cropping || modalOwnsFocus()) return
    if (document.querySelector(':popover-open:not(#canvas-messages)') || native?.paperMenu?.isConnected || native?.layoutMenu?.isConnected) return
    if (target.closest('.hakushi-paper-menu, .hakushi-layout-menu, [role="menu"], #canvas-messages, [popover]')) return
    event.preventDefault()
    event.stopImmediatePropagation()
    leave()
  }
  const updated = () => {
    if (!alive) return
    if (!hasDocument()) enabled = false
    apply()
    if (enabled && document.activeElement?.closest(hiddenChrome)) restoreFocus()
  }

  root.addEventListener('canvas:toggle-zen', toggle)
  root.addEventListener('canvas:exit-zen', exit)
  root.addEventListener('canvas:settled', updated)
  root.addEventListener('pointerdown', pointerDown, true)
  window.addEventListener('keydown', keyDown, true)
  apply()
  return {
    updated,
    // The requesting command owns the next focus move (Style/help/Open).
    reveal() { leave(false) },
    destroyed() {
      if (!alive) return
      enabled = false
      apply()
      alive = false
      root.removeEventListener('canvas:toggle-zen', toggle)
      root.removeEventListener('canvas:exit-zen', exit)
      root.removeEventListener('canvas:settled', updated)
      root.removeEventListener('pointerdown', pointerDown, true)
      window.removeEventListener('keydown', keyDown, true)
    },
  }
}
