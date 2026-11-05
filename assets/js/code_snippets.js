import {LiteralSource, enterTerminator, sourceBytes, validateSource} from './literal_source.js'

export const codeLanguages = ['auto', 'plaintext', 'elixir', 'erlang', 'javascript', 'typescript', 'json', 'html', 'css', 'shell', 'python', 'sql', 'swift', 'rust']
const make = (tag, name, text) => { const el = document.createElement(tag); el.className = name; if (text !== undefined) el.textContent = text; return el }
const codeElement = node => node?.el.querySelector('[data-code-node]')
export function codeSource(node) { try { return JSON.parse(codeElement(node)?.dataset.codeContent) } catch { return null } }
const stamp = node => {
  const el = codeElement(node)
  return {content: el?.dataset.codeContent, language: el?.dataset.codeLanguage, locked: node?.locked}
}
const sameStamp = (left, right) => left && right && left.content === right.content && left.language === right.language && left.locked === right.locked
const highlightTheme = node => {
  try { return JSON.parse(node.el.querySelector('[data-hakushi-style]')?.dataset.hakushiStyle || '{}').fill === 'ink' ? 'github-dark' : 'github-light' } catch { return 'github-light' }
}
export function codeIsClipped(root) {
  const overflows = el => el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1
  for (const pre of root.querySelectorAll('.drawing-code-source')) {
    if (pre.clientWidth || pre.clientHeight) {
      if (overflows(pre)) return true
      continue
    }
    // Culling uses display:none. Measure an uncropped copy outside the canvas
    // observers rather than treating zero live dimensions as a source fit.
    const node = pre.closest?.('.hakushi-node'), doc = root.ownerDocument
    if (!node || !doc) return true
    const width = Number(node.dataset.width), height = Number(node.dataset.height)
    if (!(width > 0 && height > 0)) return true
    const probe = doc.createElement('div'), clone = node.cloneNode(true)
    probe.className = root.className
    probe.setAttribute('aria-hidden', 'true')
    Object.assign(probe.style, {position: 'fixed', left: '-100000px', top: '0', width: '1px', height: '1px', visibility: 'hidden', pointerEvents: 'none'})
    clone.removeAttribute('id'); clone.removeAttribute('data-ui-culled')
    for (const el of clone.querySelectorAll('[id], [data-ui-culled]')) { el.removeAttribute('id'); el.removeAttribute('data-ui-culled') }
    Object.assign(clone.style, {transform: 'none', translate: 'none', width: `${width}px`, height: `${height}px`})
    probe.append(clone)
    ;(root.closest('.canvas-workspace') || root.parentElement || doc.body).append(probe)
    try {
      const measured = clone.querySelector('.drawing-code-source')
      if (!measured || !measured.clientWidth || overflows(measured)) return true
    } finally { probe.remove() }
  }
  return false
}
export function mountCodeSnippets(canvas) {
  const root = canvas.root, workspace = root.closest('#workspace')
  const generation = workspace.dataset.generation
  const directModeActive = () => workspace.workspaceHook?.activeCanvas()?.directKeyboard?.active
  let draft = null, alive = true, worker = null, scheduled = false, highlightRevision = 0
  const pendingHighlights = new Map()
  const awaitingHighlights = new Set(), highlightWaiters = new Set()
  const settleHighlights = () => {
    if (alive && workspace.dataset.generation === generation && awaitingHighlights.size) return
    for (const waiter of highlightWaiters) {
      if (alive && workspace.dataset.generation === generation) waiter.resolve()
      else waiter.reject(new Error('Canvas changed before highlighting finished.'))
    }
    highlightWaiters.clear()
  }
  const whenHighlighted = () => {
    if (!alive || workspace.dataset.generation !== generation) return Promise.reject(new Error('Canvas changed before highlighting finished.'))
    updateHighlights()
    if (!awaitingHighlights.size) return Promise.resolve()
    return new Promise((resolve, reject) => highlightWaiters.add({resolve, reject}))
  }
  let feedback = null
  const notify = (message, action = null) => {
    if (!alive || workspace.dataset.generation !== generation) return
    feedback?.remove()
    const currentFeedback = feedback = make('div', 'drawing-code-feedback')
    currentFeedback.setAttribute('role', 'status')
    const text = make('span', '', message), dismiss = make('button', '', 'Dismiss')
    const trigger = document.activeElement
    dismiss.type = 'button'
    dismiss.setAttribute('aria-label', 'Dismiss code message')
    dismiss.addEventListener('click', () => {
      if (feedback !== currentFeedback) return
      const focused = document.activeElement === dismiss
      feedback.remove(); feedback = null
      if (focused && trigger?.isConnected) trigger.focus({preventScroll: true})
    })
    currentFeedback.append(text)
    if (action) {
      const button = make('button', '', action.label); button.type = 'button'
      button.addEventListener('click', () => {
        if (feedback !== currentFeedback) return
        feedback.remove(); feedback = null; action.run()
      })
      currentFeedback.append(button)
    }
    currentFeedback.append(dismiss)
    currentFeedback.addEventListener('pointerdown', event => event.stopPropagation())
    ;(draft?.editor || canvas.ui).append(currentFeedback)
  }
  const originalPush = canvas.push.bind(canvas)
  const originalSetTool = canvas.setTool.bind(canvas)
  const requireCodeFormat = () => {
    if (workspace.dataset.documentVersion === '2') return true
    notify('Code blocks require format version 2. Download a version 2 copy and Open it, or choose New canvas. The original is not changed.', {
      label: 'Document menu',
      run: () => {
        workspace.dispatchEvent(new CustomEvent('canvas:exit-zen'))
        const trigger = workspace.querySelector('#file-menu-toggle')
        if (trigger?.getAttribute('aria-expanded') !== 'true') trigger?.click()
      },
    })
    return false
  }
  canvas.setTool = tool => {
    if (tool === 'code:block') {
      if (draft) { draft.input.focus(); return }
      if (!requireCodeFormat()) { originalSetTool(null); return }
    }
    return originalSetTool(tool)
  }
  const originalUndo = canvas.undo?.bind(canvas), originalRedo = canvas.redo?.bind(canvas)
  const editorHistory = redo => {
    if (!draft) return redo ? originalRedo?.() : originalUndo?.()
    if (draft.composing || draft.committing) return
    const input = draft.input
    const selection = draft.model.history(redo, [input.selectionStart, input.selectionEnd])
    input.value = draft.model.view; input.setSelectionRange(...selection); validity(draft)
  }
  canvas.undo = () => editorHistory(false)
  canvas.redo = () => editorHistory(true)
  const current = item => {
    const node = item.node && canvas.nodes.get(item.node.id)
    return alive && workspace.dataset.generation === generation && draft === item && (!item.node ||
      node?.type === 'code' && node.el === item.node.el && !canvas.gone.has(node.id) && node.el.isConnected && sameStamp(stamp(node), item.stamp))
  }
  const report = (item, message) => {
    item.error.textContent = message || ''; item.error.hidden = !message
    if (message) item.input.setAttribute('aria-invalid', 'true'); else item.input.removeAttribute('aria-invalid')
    return message
  }
  const validity = item => {
    const message = validateSource(item.model.source, Number(workspace.dataset.codeSourceLimit) || 262144)
    if (message) return report(item, message)
    let bytes = sourceBytes(item.model.source)
    for (const node of canvas.nodes.values()) if (node.type === 'code' && node.id !== item.node?.id && !canvas.gone.has(node.id)) bytes += sourceBytes(codeSource(node) || '')
    return report(item, bytes > (Number(workspace.dataset.codeTotalLimit) || 1048576) ? 'Code exceeds the total UTF-8 byte budget for this canvas.' : '')
  }
  const close = (item, focus = false) => {
    if (draft !== item) return
    draft = null; workspace.codeDraft = false; workspace.dataset.codeDraft = 'false'; item.editor.remove()
    canvas.drawStylePanel?.()
    if (focus && alive && root.isConnected) (item.node?.el.isConnected ? item.node.el : root).focus({preventScroll: true})
  }
  function finish() {
    const item = draft
    if (!item) return Promise.resolve(true)
    if (item.committing) return item.committing
    if (!current(item)) { close(item); canvas.announce('Code draft cancelled because its source changed.'); return Promise.reject(new Error('Code source changed; review it before saving.')) }
    if (item.composing || validity(item)) return null
    if (item.node && !item.fitOption.checked && !item.languageTouched && item.model.source === item.initial && item.language.value === item.initialLanguage) { close(item, true); return Promise.resolve(true) }
    item.input.readOnly = true; item.language.disabled = true; item.fitOption.disabled = true
    const payload = item.node ? {node: item.node.id, action: 'source', content: item.model.source} : {...item.payload, tool: 'code:block', style: {...item.payload.style, content: item.model.source, language: item.language.value}}
    if (item.node && item.languageTouched) payload.language = item.language.value
    if (item.fitOption.checked) payload.box = fittedBox(item.node && canvas.nodes.get(item.node.id), item.model.source, item.node?.el.querySelector('.drawing-code-source'))
    item.committing = new Promise((resolve, reject) => {
      item.reject = reject
      originalPush(item.node ? 'hakushi:edit' : 'hakushi:draw', payload, reply => {
        if (!alive || workspace.dataset.generation !== generation || draft !== item) { reject(new Error('Canvas changed before code editing finished.')); return }
        if (reply?.ok !== true || reply?.error || !item.node && typeof reply?.drawn !== 'string') {
          item.committing = null; item.input.readOnly = false; item.language.disabled = false; item.fitOption.disabled = false
          const message = reply?.error || 'Code was not accepted. Your draft remains editable.'
          report(item, message); reject(new Error(message)); return
        }
        close(item, true)
        if (reply.drawn) { canvas.pendingSelect = [reply.drawn]; canvas.selectPending() }
        resolve(true)
      })
    })
    return item.committing
  }
  const finishClick = () => { const pending = finish(); pending?.catch(error => canvas.announce(error.message)) }
  function start(node = null, payload = {}) {
    if (draft) { draft.input.focus(); return }
    if (canvas.config.readonly || node?.locked) { notify('Unlock this code block and use an editable canvas before editing source.'); return }
    if (workspace.dataset.nativeBusy === 'true' || workspace.dataset.fileBusy === 'true') { notify('Wait for the current file operation before editing code.'); return }
    if (directModeActive() || workspace.directPreview || workspace.dataset.attachmentBusy === 'true') { notify('Finish the active canvas mode, draft or import before editing code.'); return }
    if (!requireCodeFormat()) return
    const source = node ? codeSource(node) : ''
    if (source === null) { notify('Code source could not be read.'); return }
    if (!node && !payload.box) {
      const x = ((canvas.size?.width || 640) / 2 - (canvas.view?.x || 0)) / (canvas.view?.zoom || 1)
      const y = ((canvas.size?.height || 480) / 2 - (canvas.view?.y || 0)) / (canvas.view?.zoom || 1)
      payload = {...payload, box: [x - 160, y - 90, 320, 180]}
    }
    if (!node && payload.box) {
      const [x, y, width, height] = payload.box
      payload = {...payload, box: [x, y, width || 320, height || 180]}
    }
    feedback?.remove(); feedback = null
    const languageChoice = node ? codeElement(node).dataset.codeLanguage : 'auto'
    const editor = make('section', 'drawing-code-editor')
    editor.setAttribute('aria-label', node ? 'Edit code block' : 'Create code block')
    editor.dataset.hakushiNodrag = ''
    const pendingStatus = make('p', 'drawing-code-draft-status', 'Code draft — not committed')
    pendingStatus.setAttribute('role', 'status')
    const label = make('label', 'drawing-code-label', 'Literal code source')
    const input = make('textarea', 'drawing-code-input'); input.id = `${root.id}-code-input`; label.htmlFor = input.id
    input.wrap = 'off'; input.spellcheck = false; input.setAttribute('autocorrect', 'off'); input.setAttribute('autocapitalize', 'off'); input.setAttribute('autocomplete', 'off')
    const instructions = make('p', 'drawing-code-instructions', 'Enter inserts a newline. Tab indents two spaces; Shift+Tab unindents. Ctrl/⌘+Enter moves to language and actions. Escape or Finish commits valid source. Cancel discards this draft. Copy includes the literal draft, not highlighting.')
    instructions.id = `${input.id}-instructions`
    const error = make('p', 'drawing-code-error'); error.id = `${input.id}-error`; error.hidden = true; error.setAttribute('role', 'alert')
    input.setAttribute('aria-describedby', `${instructions.id} ${error.id}`)
    const languageLabel = make('label', 'drawing-code-label', 'Language')
    const language = make('select', 'drawing-code-language'); language.id = `${input.id}-language`; languageLabel.htmlFor = language.id
    for (const choice of codeLanguages.includes(languageChoice) ? codeLanguages : [...codeLanguages, languageChoice]) {
      const option = make('option', '', choice === 'auto' ? 'Auto detect' : choice === 'plaintext' ? 'Plain text' : codeLanguages.includes(choice) ? choice : `Unsupported: ${choice}`); option.value = choice; language.append(option)
    }
    language.value = languageChoice
    const actions = make('div', 'drawing-code-actions')
    const utilities = make('div', 'drawing-code-utilities'), completion = make('div', 'drawing-code-completion')
    const fitOption = make('input', 'drawing-code-fit'); fitOption.type = 'checkbox'; fitOption.id = `${input.id}-fit`; fitOption.checked = false
    const fitLabel = make('label', 'drawing-code-fit-option'); fitLabel.htmlFor = fitOption.id
    fitLabel.append(fitOption, make('span', '', 'Fit to content'))
    const item = draft = {editor, input, language, error, fitOption, node, payload, stamp: stamp(node), initial: source, initialLanguage: languageChoice, model: new LiteralSource(source), composing: false}
    language.addEventListener('change', () => { item.languageTouched = true })
    workspace.codeDraft = true; workspace.dataset.codeDraft = 'true'
    canvas.drawStylePanel?.()
    const sync = selection => { input.value = item.model.view; if (selection) input.setSelectionRange(...selection); validity(item) }
    sync()
    const selection = () => [input.selectionStart, input.selectionEnd]
    input.addEventListener('compositionstart', () => { item.composing = true; item.beforeSelection = selection() })
    input.addEventListener('compositionend', () => { item.composing = false; item.model.reconcile(input.value, item.beforeSelection || selection()); validity(item) })
    input.addEventListener('input', () => { if (!item.composing) { item.model.reconcile(input.value, item.beforeSelection || selection()); validity(item) } })
    input.addEventListener('paste', event => {
      if (!event.clipboardData || item.composing || item.committing) return
      event.preventDefault(); sync(item.model.replace(...selection(), event.clipboardData.getData('text/plain')))
    })
    input.addEventListener('keydown', event => {
      event.stopPropagation()
      if (event.isComposing || event.keyCode === 229 || item.composing || item.committing) return
      if (event.key === 'Escape') { event.preventDefault(); finishClick() }
      else if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) { event.preventDefault(); language.focus({preventScroll: true}) }
      else if ((event.metaKey || event.ctrlKey) && ['z', 'y'].includes(event.key.toLowerCase())) { event.preventDefault(); sync(item.model.history(event.key.toLowerCase() === 'y' || event.shiftKey, selection())) }
      else if (event.key === 'Tab' && !event.metaKey && !event.ctrlKey && !event.altKey) { event.preventDefault(); sync(item.model.indent(...selection(), event.shiftKey)) }
      else if (event.key === 'Enter' && !event.metaKey && !event.ctrlKey && !event.altKey) { event.preventDefault(); sync(item.model.replace(...selection(), enterTerminator(item.model.source, input.selectionStart))) }
    })
    input.addEventListener('beforeinput', event => {
      if (item.committing) { event.preventDefault(); return }
      if (item.composing || event.isComposing) return
      item.beforeSelection = selection()
      if (event.inputType === 'historyUndo' || event.inputType === 'historyRedo') {
        event.preventDefault(); sync(item.model.history(event.inputType === 'historyRedo', selection())); return
      }
      let [start, end] = selection(), inserted = null
      if (event.inputType === 'insertText' && typeof event.data === 'string') inserted = event.data
      else if (['insertLineBreak', 'insertParagraph'].includes(event.inputType)) inserted = enterTerminator(item.model.source, start)
      else if (['deleteContentBackward', 'deleteContentForward', 'deleteByCut'].includes(event.inputType)) {
        inserted = ''
        if (start === end && event.inputType !== 'deleteByCut') {
          const boundaries = typeof Intl.Segmenter === 'function' ? [...new Intl.Segmenter(undefined, {granularity: 'grapheme'}).segment(item.model.view)].map(segment => segment.index) : [...item.model.view].reduce((list, char) => [...list, list.at(-1) + char.length], [0])
          boundaries.push(item.model.view.length)
          if (event.inputType === 'deleteContentBackward') start = boundaries.findLast(index => index < start) ?? 0
          else end = boundaries.find(index => index > end) ?? end
        }
      }
      if (inserted !== null) { event.preventDefault(); sync(item.model.replace(start, end, inserted, item.beforeSelection)) }
    })
    const copyButton = make('button', '', 'Copy code'); copyButton.type = 'button'
    copyButton.addEventListener('click', () => copy(item.model.source))
    utilities.append(copyButton, fitLabel)
    const cancel = make('button', '', 'Cancel'); cancel.type = 'button'
    cancel.addEventListener('click', () => { if (!item.committing) close(item, true) })
    const finishButton = make('button', 'drawing-code-finish', 'Finish'); finishButton.type = 'button'
    finishButton.addEventListener('click', finishClick)
    completion.append(cancel, finishButton)
    actions.append(utilities, completion)
    editor.append(pendingStatus, label, instructions, input, languageLabel, language, error, actions)
    editor.addEventListener('pointerdown', event => {
      event.stopPropagation()
      // Safari does not focus clicked controls consistently; keep action/option
      // focus inside the editor before textarea blur can commit a pending draft.
      const control = event.target.closest('button, input') || event.target.closest('label')?.control
      // A label's default mousedown can move focus back to body before its
      // forwarded checkbox click. Preserve our focus without cancelling click,
      // so the native checkbox still owns toggling and keyboard semantics.
      if (control?.type === 'checkbox') event.preventDefault()
      control?.focus({preventScroll: true})
    })
    editor.addEventListener('wheel', event => event.stopPropagation())
    editor.addEventListener('keydown', event => {
      event.stopPropagation()
      if (event.key === 'Escape' && !event.defaultPrevented && !event.isComposing && event.keyCode !== 229 && !item.composing) { event.preventDefault(); finishClick() }
    })
    editor.addEventListener('focusout', event => {
      if (item.editor.contains(event.relatedTarget) || event.relatedTarget?.closest('[data-zen-toggle]')) return
      queueMicrotask(() => {
        if (draft === item && !item.editor.contains(document.activeElement) && document.hasFocus() && !document.activeElement?.closest('[data-zen-toggle]')) finishClick()
      })
    })
    canvas.ui.append(editor); input.focus({preventScroll: true})
  }
  async function copy(source) {
    try { await navigator.clipboard.writeText(source); notify('Literal code copied.') }
    catch (error) { notify(`Could not copy code: ${error.message}`) }
  }
  function fittedBox(node, source, reference) {
    const measure = make('pre', 'drawing-code-source'); measure.textContent = source || ' '
    Object.assign(measure.style, {position: 'absolute', width: 'max-content', height: 'auto', maxWidth: 'none', maxHeight: 'none', visibility: 'hidden', overflow: 'visible'})
    if (reference) { const style = getComputedStyle(reference); measure.style.font = style.font; measure.style.lineHeight = style.lineHeight }
    canvas.ui.append(measure)
    const footer = reference && node ? Math.max(0, node.height - reference.clientHeight) : 96
    const width = Math.ceil(measure.scrollWidth + 4), height = Math.ceil(measure.scrollHeight + 4 + footer); measure.remove()
    const box = draft?.payload.box || [0, 0, 320, 180]
    return [node?.x ?? box[0], node?.y ?? box[1], Math.max(80, width), Math.max(48, height)]
  }
  function fit(node) {
    if (draft) { draft.fitOption.checked = true; finishClick(); return }
    if (node.locked || canvas.config.readonly) return
    originalPush('hakushi:edit', {node: node.id, action: 'source', content: codeSource(node), box: fittedBox(node, codeSource(node), node.el.querySelector('.drawing-code-source'))}, reply => { if (reply?.error) notify(reply.error) })
  }
  canvas.push = (event, payload, callback) => {
    if (event === 'hakushi:draw' && payload.tool === 'code:block') { start(null, payload); canvas.setTool(null); return }
    if (draft && ['hakushi:draw', 'hakushi:change', 'hakushi:edit', 'drawing:stack', 'drawing:edge-style'].includes(event)) { canvas.announce('Finish or cancel the code draft before changing the canvas.'); callback?.({ok: false, error: 'Finish or cancel the code draft first.'}); return }
    return originalPush(event, payload, callback)
  }
  const flush = event => {
    if (!draft) return
    if (!event.detail?.waiters) {
      if (validity(draft) || draft.composing || draft.committing || draft.fitOption.checked || draft.model.source !== draft.initial || draft.language.value !== draft.initialLanguage || !draft.node) { event.preventDefault(); report(draft, draft.error.textContent || 'Finish this code draft before opening another file.'); return }
      close(draft); return
    }
    const pending = finish()
    if (!pending) event.preventDefault(); else event.detail.waiters.push(pending)
  }
  const sourcePointerDown = event => {
    if (canvas.tool || canvas.space || canvas.gesture) return
    const pre = event.target.closest('.drawing-code-source')
    if (!pre || event.target !== pre) return
    // Native scrollbars keep their pointer interaction; the source body uses
    // Hakushi's ordinary selection/drag/history path.
    if (pre.offsetWidth > pre.clientWidth && event.offsetX >= pre.clientWidth ||
        pre.offsetHeight > pre.clientHeight && event.offsetY >= pre.clientHeight) event.stopPropagation()
  }
  const sourceWheel = event => {
    if (event.ctrlKey || event.metaKey || canvas.tool || canvas.space || canvas.gesture) return
    const pre = event.target.closest('.drawing-code-source')
    if (!pre) return
    const horizontal = event.deltaX || (event.shiftKey && event.deltaY)
    const vertical = !event.shiftKey && event.deltaY
    if (horizontal && pre.scrollWidth > pre.clientWidth ||
        vertical && pre.scrollHeight > pre.clientHeight) event.stopPropagation()
  }
  const activation = event => {
    const element = event.type === 'dblclick' ? document.elementFromPoint?.(event.clientX, event.clientY) || event.target : event.target
    const create = element.closest('[data-code-create]')
    const wrapper = element.closest('.hakushi-node')
    const node = wrapper && canvas.nodes.get(wrapper.dataset.id)
    if (create) { start(); return }
    if (node?.type !== 'code') return
    const edit = element.closest('[data-code-edit]'), copyButton = element.closest('[data-code-copy]'), fitButton = element.closest('[data-code-fit]')
    if (event.type === 'dblclick' || edit || copyButton || fitButton) {
      event.preventDefault(); event.stopImmediatePropagation()
      if (copyButton) copy(draft?.node === node ? draft.model.source : codeSource(node)); else if (fitButton) fit(node); else start(node)
    }
  }
  const keyboard = event => {
    if (event.defaultPrevented || event.isComposing || event.keyCode === 229 || event.metaKey || event.ctrlKey || event.altKey || event.target.closest('input, textarea, select, button')) return
    if (draft && event.key === 'Escape') { event.preventDefault(); event.stopImmediatePropagation(); finishClick(); return }
    if (!['Enter', 'F2'].includes(event.key) || canvas.tool || canvas.gesture || directModeActive()) return
    const node = canvas.focusedNode()
    if (node?.type === 'code') { event.preventDefault(); event.stopImmediatePropagation(); start(node) }
  }
  function updateHighlights() {
    scheduled = false
    if (!alive) return
    if (draft && !draft.committing && !current(draft)) { close(draft); canvas.announce('Code draft cancelled because its source changed.') }
    for (const [id, pending] of pendingHighlights) {
      const node = canvas.nodes.get(id)
      if (!node || node.type !== 'code' || canvas.gone.has(id) || node.el !== pending.nodeEl) {
        pendingHighlights.delete(id); awaitingHighlights.delete(id)
      }
    }
    for (const node of canvas.nodes.values()) {
      if (node.type !== 'code' || canvas.gone.has(node.id)) continue
      const el = codeElement(node)
      if (!el) continue
      const pre = el.querySelector('.drawing-code-source'), status = el.querySelector('.drawing-code-highlight-status'), overflow = el.querySelector('.drawing-code-overflow')
      if (overflow && pre) {
        const hidden = !(pre.scrollWidth > pre.clientWidth + 1 || pre.scrollHeight > pre.clientHeight + 1)
        if (overflow.hidden !== hidden) overflow.hidden = hidden
        const message = 'Some source is hidden. Scroll to inspect or choose Fit to source before exporting.'
        if (overflow.textContent !== message) overflow.textContent = message
      }
      const sourceStamp = stamp(node), theme = highlightTheme(node)
      const cached = pendingHighlights.get(node.id)
      if (cached?.nodeEl === node.el && cached.element === pre && cached.theme === theme && sameStamp(cached.stamp, sourceStamp)) continue
      const source = codeSource(node)
      if (typeof source !== 'string') continue
      const revision = ++highlightRevision
      pendingHighlights.set(node.id, {revision, nodeEl: node.el, stamp: sourceStamp, theme, source, element: pre})
      if (worker) awaitingHighlights.add(node.id)
      const message = worker ? 'Highlighting…' : 'Highlighting unavailable; literal plain text'
      if (status && status.textContent !== message) status.textContent = message
      worker?.postMessage({generation, node: node.id, revision, source, language: el.dataset.codeLanguage, theme})
    }
    settleHighlights()
  }
  try {
    if (workspace.dataset.codeWorker && typeof Worker === 'function') {
      worker = new Worker(workspace.dataset.codeWorker)
      worker.addEventListener('message', ({data}) => {
        const pending = pendingHighlights.get(data.node), node = canvas.nodes.get(data.node)
        if (!alive || data.generation !== generation || workspace.dataset.generation !== generation || !pending || pending.nodeEl !== node?.el || canvas.gone.has(data.node) || pending.revision !== data.revision || !sameStamp(pending.stamp, stamp(node)) || pending.theme !== highlightTheme(node) || pending.element !== codeElement(node)?.querySelector('.drawing-code-source')) return
        awaitingHighlights.delete(data.node)
        const el = codeElement(node), target = el.querySelector('.drawing-code-source code') || el.querySelector('.drawing-code-source'), status = el.querySelector('.drawing-code-highlight-status')
        const message = data.error || data.status
        if (status && status.textContent !== message) status.textContent = message
        if (data.error || !Array.isArray(data.tokens) || data.tokens.map(token => token.text).join('') !== pending.source) {
          if (status) status.textContent = data.error || 'Highlighting unavailable; literal plain text'
          if (target) target.textContent = pending.source
          settleHighlights(); return
        }
        const fragment = document.createDocumentFragment()
        for (const token of data.tokens) { const span = make('span', '', token.text); if (/^#[0-9a-f]{3,8}$/i.test(token.color || '')) span.style.color = token.color; fragment.append(span) }
        target?.replaceChildren(fragment)
        settleHighlights()
      })
      worker.addEventListener('error', () => { worker?.terminate(); worker = null; pendingHighlights.clear(); awaitingHighlights.clear(); updateHighlights() })
    }
  } catch { worker = null }
  const schedule = () => { if (!scheduled) { scheduled = true; queueMicrotask(updateHighlights) } }
  const observer = new MutationObserver(schedule)
  observer.observe(root, {subtree: true, childList: true, attributes: true, attributeFilter: ['data-code-content', 'data-code-language', 'data-code-size', 'data-hakushi-style', 'style']})
  const resize = typeof ResizeObserver === 'function' ? new ResizeObserver(schedule) : null
  resize?.observe(root)
  workspace.addEventListener('canvas:flush', flush)
  workspace.addEventListener('click', activation, true)
  root.addEventListener('dblclick', activation, true)
  root.addEventListener('keydown', keyboard, true)
  root.addEventListener('pointerdown', sourcePointerDown, true)
  root.addEventListener('wheel', sourceWheel, {capture: true, passive: true})
  schedule()
  return {start, finish, notify, whenHighlighted, destroy() {
    alive = false
    settleHighlights()
    if (draft) { draft.reject?.(new Error('Canvas closed before code editing finished.')); close(draft) }
    worker?.terminate(); observer.disconnect(); resize?.disconnect()
    feedback?.remove()
    workspace.removeEventListener('canvas:flush', flush); workspace.removeEventListener('click', activation, true)
    root.removeEventListener('dblclick', activation, true); root.removeEventListener('keydown', keyboard, true)
    root.removeEventListener('pointerdown', sourcePointerDown, true)
    root.removeEventListener('wheel', sourceWheel, true)
    canvas.push = originalPush
    canvas.setTool = originalSetTool
    canvas.undo = originalUndo; canvas.redo = originalRedo
  }}
}
