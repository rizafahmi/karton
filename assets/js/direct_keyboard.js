// Geometry is in canvas pixels, never screen pixels. Only the new box moves.
export function adjacentThoughtBox(source, obstacles, direction, height = 96) {
  const width = 160, gap = 48
  const bounds = node => {
    const angle = (node.rotation || 0) * Math.PI / 180
    const w = Math.abs(Math.cos(angle)) * node.width + Math.abs(Math.sin(angle)) * node.height
    const h = Math.abs(Math.sin(angle)) * node.width + Math.abs(Math.cos(angle)) * node.height
    return {x: node.x + (node.width - w) / 2, y: node.y + (node.height - h) / 2, width: w, height: h}
  }
  const origin = bounds(source)
  const horizontal = direction === 'ArrowLeft' || direction === 'ArrowRight'
  const forward = direction === 'ArrowRight' || direction === 'ArrowDown'
  const axis = horizontal ? 'x' : 'y', span = horizontal ? 'width' : 'height'
  const cross = horizontal ? 'y' : 'x', crossSpan = horizontal ? 'height' : 'width'
  const box = {x: source.x + (source.width - width) / 2, y: source.y + (source.height - height) / 2, width, height}
  box[cross] = Math.round(box[cross] * 10) / 10
  box[axis] = forward ? origin[axis] + origin[span] + gap : origin[axis] - box[span] - gap
  const blockers = obstacles.map(bounds).filter(other =>
    box[cross] < other[cross] + other[crossSpan] + gap &&
    box[cross] + box[crossSpan] + gap > other[cross])
  // Every pass moves past a blocker. Finite nodes, no arbitrary search cutoff.
  for (let pass = 0; pass <= blockers.length; pass++) {
    const overlaps = blockers.filter(other =>
      box[axis] < other[axis] + other[span] + gap &&
      box[axis] + box[span] + gap > other[axis])
    if (!overlaps.length) break
    box[axis] = forward
      ? Math.max(...overlaps.map(other => other[axis] + other[span] + gap))
      : Math.min(...overlaps.map(other => other[axis] - box[span] - gap))
  }
  // Hakushi persists tenths. Round outwards so the preview is the authored box.
  box[axis] = (forward ? Math.ceil : Math.floor)(box[axis] * 10) / 10
  return box
}

// Keyboard routes operate on the same graph, decoration and history as pointer gestures.
export function mountDirectKeyboard(canvas) {
  let mode = null, cursor = null, navigating = false, helpObserver = null, spacePending = null, pendingFocus = null
  const root = canvas.root
  const workspace = root.closest('#workspace')
  const corners = ['se', 's', 'sw', 'w', 'nw', 'n', 'ne', 'e', 'rotation']
  const sides = [null, 'right', 'bottom', 'left', 'top']
  const single = () => canvas.selected.size === 1 ? canvas.nodes.get([...canvas.selected][0]) : null
  const edge = () => canvas.selectedEdges.size === 1 ? canvas.edges.get([...canvas.selectedEdges][0]) : null
  const mutable = node => node && !node.locked && !canvas.config.readonly && !canvas.gone.has(node.id)
  const send = (event, payload) => canvas.push(event, payload, reply => {
    if (reply.error || reply.ok === false) canvas.announce(reply.error || 'Edit was refused.')
  })
  const marker = document.createElement('div')
  marker.className = 'drawing-keyboard-marker'
  marker.hidden = true
  marker.setAttribute('aria-hidden', 'true')
  canvas.ui.append(marker)
  const items = () => [...canvas.order.filter(id => !canvas.gone.has(id)).map(id => ({id, node: true})), ...[...canvas.edges.keys()].filter(id => !canvas.gone.has(id)).map(id => ({id, node: false}))]
  const focusIn = canvas.focusIn.bind(canvas)
  canvas.focusIn = event => { if (!navigating) { cursor = null; focusIn(event) } }
  function focusItem(item) {
    cursor = item
    if (item.node) {
      const node = canvas.nodes.get(item.id)
      canvas.culled.delete(item.id)
      node.el.removeAttribute('data-ui-culled')
      // Native streamed-node removal recovers canvas focus through this reference.
      canvas.lastFocus = node.el
      navigating = true
      node.el.focus({preventScroll: true})
      navigating = false
      canvas.revealNodes([item.id])
      canvas.announce(`${node.label || node.type}. Space toggles selection; G edits geometry.`)
    } else {
      navigating = true
      root.focus({preventScroll: true})
      navigating = false
      const current = canvas.edges.get(item.id)
      canvas.revealNodes([current.source, current.target])
      canvas.announce(`Connection ${current.label || item.id}. Space toggles selection; Enter edits label; C reconnects.`)
    }
    canvas.schedule()
  }
  function toggleItem() {
    const item = document.activeElement?.classList.contains('hakushi-node') ? {id: document.activeElement.dataset.id, node: true} : cursor
    if (!item) return false
    const selected = new Set(item.node ? canvas.selected : canvas.selectedEdges)
    selected.has(item.id) ? selected.delete(item.id) : selected.add(item.id)
    if (item.node) canvas.setSelection(selected)
    else canvas.selectedEdges = selected
    canvas.selectionChanged()
    return true
  }
  const styleOf = node => node.el.querySelector('[data-hakushi-rotate]')
  const rotation = node => parseFloat(getComputedStyle(styleOf(node) || node.el).getPropertyValue('--hakushi-rotation')) || 0
  const selectionStamp = () => JSON.stringify([[...canvas.selected].sort(), [...canvas.selectedEdges].sort()])
  const sourceStamp = node => JSON.stringify([
    node.x, node.y, node.width, node.height, rotation(node), node.locked,
    node.el.querySelector('[data-hakushi-text]')?.dataset.hakushiText,
    node.el.querySelector('[data-hakushi-style]')?.dataset.hakushiStyle,
    node.el.querySelector('.drawing-typography')?.dataset.drawingFont,
    workspace.dataset?.drawingFont,
  ])
  function validThought(current) {
    return mutable(current.source) && !canvas.tool && !canvas.gesture &&
      canvas.nodes.get(current.source.id) === current.source && current.source.el.isConnected &&
      sourceStamp(current.source) === current.stamp && selectionStamp() === current.selection
  }
  function cancelThought(refocus = false) {
    const current = mode
    if (current?.kind !== 'thought' || current.committing) return
    mode = null
    workspace.directPreview = false
    current.preview.remove()
    if (refocus && mutable(current.source) && current.source.el.isConnected) focusItem({id: current.source.id, node: true})
    canvas.schedule()
  }
  function revealThought(current) {
    const box = current.box || {x: current.source.x, y: current.source.y + current.source.height + 12, width: 160}
    const bounds = root.getBoundingClientRect?.() || {left: 0, top: 0}
    const rail = canvas.controlsEl?.getBoundingClientRect()
    const header = workspace.querySelector('.canvas-header')?.getBoundingClientRect()
    const safeLeft = rail ? Math.max(24, rail.right - bounds.left + 12) : 24
    const right = canvas.size.width - 24
    const top = header ? Math.max(24, header.bottom - bounds.top + 12) : 24
    const dock = canvas.toolsEl?.getBoundingClientRect()
    const bottom = dock
      ? Math.min(canvas.size.height - 24, dock.top - bounds.top - 24)
      : canvas.size.height - 120
    // Measure UI at screen size, then cancel the world's scale for the hint.
    const hintWidth = Math.min(280, right - safeLeft)
    Object.assign(current.hint.style, {fontSize: '11px', width: `${hintWidth}px`, padding: '4px 6px', borderWidth: '1px'})
    const hintHeight = parseFloat(getComputedStyle(current.hint).height) || current.hint.offsetHeight || 48
    let zoom = Math.min(canvas.view.zoom, (right - safeLeft) / box.width)
    if (current.input) {
      const lineHeight = parseFloat(getComputedStyle(current.input).lineHeight) || 24
      // Fit one line plus ordinary padding, never the full authored text height.
      zoom = Math.min(zoom, (bottom - top - hintHeight - 12) / (lineHeight + 16))
    }
    Object.assign(current.hint.style, {
      fontSize: `${11 / zoom}px`, width: `${hintWidth / zoom}px`,
      padding: `${4 / zoom}px ${6 / zoom}px`, borderWidth: `${1 / zoom}px`,
    })
    let visibleHeight = hintHeight
    if (current.input) {
      const height = Math.min(box.height, (bottom - top - hintHeight - 12) / zoom)
      current.input.style.height = `${height}px`
      current.input.style.paddingBlock = `${height < box.height ? 8 : 8 + (box.height - current.mirror.scrollHeight) / 2}px`
      current.input.style.overflowY = height < box.height ? 'auto' : 'hidden'
      current.hint.style.top = `${height + 8 / zoom}px`
      visibleHeight += height * zoom + 8
      if (current.input.selectionEnd === current.input.value.length) current.input.scrollTop = current.input.scrollHeight
    }
    const width = Math.max(box.width * zoom, hintWidth)
    const left = box.x * zoom + canvas.view.x, y = box.y * zoom + canvas.view.y
    canvas.view = {...canvas.view, zoom,
      x: canvas.view.x + (left < safeLeft ? safeLeft - left : Math.min(0, right - left - width)),
      y: canvas.view.y + (y < top ? top - y : Math.min(0, bottom - y - visibleHeight))}
    canvas.schedule()
  }
  function thoughtError(current, message) {
    current.hint.textContent = message
    current.input?.setAttribute('aria-invalid', 'true')
    current.input?.focus({preventScroll: true})
    revealThought(current)
    canvas.announce(message)
  }
  function measureThought() {
    const current = mode
    if (current?.kind !== 'thought' || !current.input || current.committing) return
    if (!validThought(current)) { cancelThought(); return }
    current.mirror.textContent = current.input.value + '\u200b'
    const height = Math.max(96, Math.ceil(current.mirror.scrollHeight))
    const source = {...current.source, rotation: rotation(current.source)}
    const obstacles = [...canvas.nodes.values()].filter(node => !canvas.gone.has(node.id))
      .map(node => ({...node, rotation: rotation(node)}))
    current.box = adjacentThoughtBox(source, obstacles, current.direction, height)
    const {x, y, width} = current.box
    Object.assign(current.preview.style, {translate: `${x}px ${y}px`, width: `${width}px`, height: `${height}px`})
    current.input.removeAttribute('aria-invalid')
    current.hint.textContent = 'Enter adds · Shift+Enter newline · Escape cancels'
    revealThought(current)
    canvas.schedule()
  }
  function startThoughtText(direction) {
    const current = mode
    if (current.committing) return
    if (current.input) { current.input.focus({preventScroll: true}); return }
    if (!validThought(current)) { cancelThought(); return }
    current.direction = direction
    const mirror = current.mirror = document.createElement('div')
    mirror.className = 'hakushi-shape-text drawing-thought-measure'
    mirror.dataset.align = 'left'
    mirror.setAttribute('aria-hidden', 'true')
    const input = current.input = document.createElement('textarea')
    input.className = 'hakushi-shape-text drawing-thought-input'
    input.setAttribute('aria-label', 'New adjacent thought')
    input.setAttribute('aria-describedby', current.hint.id)
    input.setAttribute('spellcheck', 'true')
    input.addEventListener('pointerdown', event => event.stopPropagation())
    input.addEventListener('wheel', event => event.stopPropagation(), {passive: true})
    input.addEventListener('input', measureThought)
    input.addEventListener('keydown', event => {
      event.stopPropagation()
      if (event.isComposing || event.keyCode === 229) return
      if (event.key === 'Escape') { event.preventDefault(); cancelThought(true) }
      else if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); finishThought() }
    })
    current.preview.prepend(mirror, input)
    measureThought()
    input.focus({preventScroll: true})
  }
  function thought() {
    const element = document.activeElement
    const node = element?.classList.contains('hakushi-node')
      ? canvas.nodes.get(element.dataset.id)
      : element === root && cursor?.node !== false && canvas.selectedEdges.size === 0 ? single() : null
    if (!mutable(node) || node.type !== 'shape' || !node.el.querySelector('[data-hakushi-text]') || canvas.tool || canvas.gesture) return
    const preview = document.createElement('div')
    preview.className = 'drawing-thought-preview drawing-thought-choosing'
    const hint = document.createElement('div')
    hint.className = 'drawing-thought-hint'
    hint.id = `${root.id}-thought-hint`
    hint.textContent = 'Choose ↑ → ↓ ← · Escape cancels · No automatic link'
    preview.append(hint)
    canvas.labelsEl.append(preview)
    mode = {kind: 'thought', source: node, stamp: sourceStamp(node), selection: selectionStamp(), preview, hint}
    Object.assign(preview.style, {translate: `${node.x}px ${node.y + node.height + 12}px`, width: '160px'})
    revealThought(mode)
    workspace.directPreview = true
    root.focus({preventScroll: true})
    canvas.announce(hint.textContent)
  }
  function finishThought(saving = false) {
    const current = mode
    if (current?.kind !== 'thought') return Promise.resolve(true)
    if (current.committing) return current.committing
    if (!validThought(current)) {
      cancelThought()
      canvas.announce('Adjacent thought cancelled because its source or selection changed.')
      return Promise.resolve(true)
    }
    if (!current.input) {
      if (saving) { cancelThought(); canvas.announce('Direction-only adjacent thought cancelled before saving.'); return Promise.resolve(true) }
      return null
    }
    // Match Shapes' grapheme limit without truncating pasted text or IME input.
    if (typeof Intl.Segmenter !== 'function') {
      thoughtError(current, 'This browser cannot count text safely. Update it to add an adjacent thought.')
      return null
    }
    if ([...new Intl.Segmenter(undefined, {granularity: 'grapheme'}).segment(current.input.value)].length > 2000) {
      thoughtError(current, 'Thought exceeds the existing 2,000-character limit. Shorten it or Escape; nothing was added or saved.')
      return null
    }
    measureThought()
    const {x, y, width, height} = current.box
    current.input.readOnly = true
    current.hint.textContent = 'Adding thought…'
    canvas.announce(current.hint.textContent)
    revealThought(current)
    current.preview.classList.remove('drawing-thought-choosing')
    current.committing = new Promise(resolve => {
      canvas.push('hakushi:draw', {tool: 'drawing:rect', box: [x, y, width, height], style: {text: current.input.value}}, reply => {
        if (typeof reply.drawn !== 'string' || reply.error || reply.ok === false) {
          current.committing = null
          current.input.readOnly = false
          thoughtError(current, reply.error || 'Thought was not added. Your draft is still here; try again or Escape.')
          resolve(false)
          return
        }
        const continueFocus = document.activeElement === current.input || document.activeElement === root
        mode = null
        workspace.directPreview = false
        current.preview.remove()
        if (continueFocus) { root.focus({preventScroll: true}); pendingFocus = reply.drawn }
        canvas.pendingSelect = [reply.drawn]
        canvas.selectPending()
        resolve(true)
      })
    })
    return current.committing
  }
  const selectPending = canvas.selectPending.bind(canvas)
  canvas.selectPending = () => {
    selectPending()
    if (pendingFocus && canvas.nodes.has(pendingFocus)) {
      const id = pendingFocus
      pendingFocus = null
      if (document.activeElement === root) focusItem({id, node: true})
    }
  }
  const nodesChanged = canvas.nodesChanged.bind(canvas)
  canvas.nodesChanged = records => {
    nodesChanged(records)
    if (mode?.kind === 'thought' && !mode.committing) {
      if (!validThought(mode)) cancelThought()
      else measureThought()
    }
  }
  const selectionChanged = canvas.selectionChanged.bind(canvas)
  canvas.selectionChanged = () => {
    if (mode?.kind === 'thought' && !mode.committing && selectionStamp() !== mode.selection) cancelThought()
    selectionChanged()
  }
  const setTool = canvas.setTool.bind(canvas)
  canvas.setTool = tool => { if (mode?.kind === 'thought') cancelThought(); setTool(tool) }
  const update = canvas.update.bind(canvas)
  canvas.update = () => {
    update()
    if (mode?.kind === 'thought' && !validThought(mode)) cancelThought()
  }
  const undo = canvas.undo.bind(canvas), redo = canvas.redo.bind(canvas)
  canvas.undo = () => { if (mode?.kind === 'thought') cancelThought(); undo() }
  canvas.redo = () => { if (mode?.kind === 'thought') cancelThought(); redo() }
  function geometry() {
    const node = single()
    if (!mutable(node) || canvas.gesture || canvas.tool) return
    const box = {x: node.x, y: node.y, width: node.width, height: node.height}
    const element = styleOf(node)
    mode = {kind: 'geometry', node, box, angle: rotation(node), originalAngle: rotation(node), declaration: element?.style.getPropertyValue('--hakushi-rotation'), handle: 0}
    if (node.type === 'shape-line') {
      const aim = node.el.querySelector('.hakushi-shape-line-aim')
      mode.points = [[node.x + Number(aim.getAttribute('x1')), node.y + Number(aim.getAttribute('y1'))], [node.x + Number(aim.getAttribute('x2')), node.y + Number(aim.getAttribute('y2'))]]
      mode.originalPoints = mode.points.map(point => [...point])
    }
    root.focus({preventScroll: true})
    describeMode()
    canvas.schedule()
  }
  function describeMode() {
    if (mode.kind === 'geometry') canvas.announce(`${mode.points ? ['Start endpoint', 'End endpoint'][mode.handle] : corners[mode.handle]}. Arrows preview; Shift for ten; Tab changes handle; Enter commits; Escape cancels.`)
    else {
      const end = mode.stage < 2 ? 'source' : 'target'
      const node = canvas.nodes.get(mode[end])
      canvas.announce(`${end} ${mode.stage % 2 ? 'side' : 'object'}: ${mode.stage % 2 ? mode[end + 'Handle'] || 'Automatic' : node?.label || node?.id}. Arrows or Tab choose; Enter advances; Escape cancels.`)
      canvas.revealNodes([mode.source, mode.target])
    }
  }
  function restoreGeometry(current) {
    Object.assign(current.node, current.box)
    const element = styleOf(current.node)
    if (element) current.declaration ? element.style.setProperty('--hakushi-rotation', current.declaration) : element.style.removeProperty('--hakushi-rotation')
    canvas.decorate(current.node)
    canvas.measureHandles(current.node)
    canvas.touchNode(current.node.id)
  }
  function finishGeometry(commit) {
    const current = mode, node = current.node
    const box = [node.x, node.y, node.width, node.height]
    const changed = box.some((value, index) => value !== Object.values(current.box)[index])
    restoreGeometry(current)
    mode = null
    workspace.directPreview = false
    marker.hidden = true
    if (commit && mutable(node)) {
      if (current.points && JSON.stringify(current.points) !== JSON.stringify(current.originalPoints)) {
        const [from, to] = current.points
        const x = Math.min(from[0], to[0]) - 12, y = Math.min(from[1], to[1]) - 12
        send('hakushi:edit', {node: node.id, action: 'endpoints', from: [from[0] - x, from[1] - y], to: [to[0] - x, to[1] - y], box: [x, y, Math.abs(to[0] - from[0]) + 24, Math.abs(to[1] - from[1]) + 24]})
      } else if (!current.points && current.angle !== current.originalAngle) send('hakushi:edit', {node: node.id, action: 'rotate', value: current.angle, ...(changed ? {box} : {})})
      else if (!current.points && changed) send('hakushi:change', {op: 'move', nodes: [{id: node.id, x: box[0], y: box[1], width: box[2], height: box[3]}]})
    }
    canvas.schedule()
  }
  function moveHandle(dx, dy, step) {
    const current = mode, node = current.node, handle = corners[current.handle]
    if (!mutable(node)) return finishGeometry(false)
    if (current.points) {
      current.points[current.handle][0] += dx * step
      current.points[current.handle][1] += dy * step
    } else if (handle === 'rotation') {
      current.angle += (dx || -dy) * step
      styleOf(node)?.style.setProperty('--hakushi-rotation', `${current.angle}deg`)
    } else {
      // Move a handle in its local axes, keeping the opposite rotated anchor fixed.
      const theta = current.angle * Math.PI / 180, cos = Math.cos(theta), sin = Math.sin(theta)
      const oldWidth = node.width, oldHeight = node.height
      const localX = (dx * cos + dy * sin) * step, localY = (-dx * sin + dy * cos) * step
      if (handle.includes('e')) node.width = Math.max(1, node.width + localX)
      if (handle.includes('w')) node.width = Math.max(1, node.width - localX)
      if (handle.includes('s')) node.height = Math.max(1, node.height + localY)
      if (handle.includes('n')) node.height = Math.max(1, node.height - localY)
      const x = (node.width - oldWidth) * (handle.includes('w') ? -0.5 : 0.5)
      const y = (node.height - oldHeight) * (handle.includes('n') ? -0.5 : 0.5)
      node.x += x * cos - y * sin - (node.width - oldWidth) / 2
      node.y += x * sin + y * cos - (node.height - oldHeight) / 2
    }
    canvas.decorate(node)
    canvas.measureHandles(node)
    canvas.touchNode(node.id)
    workspace.directPreview = current.points
      ? JSON.stringify(current.points) !== JSON.stringify(current.originalPoints)
      : current.angle !== current.originalAngle || Object.keys(current.box).some(key => node[key] !== current.box[key])
    canvas.schedule()
  }
  function connect() {
    if (canvas.config.readonly || canvas.gesture) return
    const focused = document.activeElement?.classList.contains('hakushi-node')
    const existing = !focused && edge(), node = existing ? canvas.nodes.get(existing.source) : canvas.focusedNode()
    if (!mutable(node) || !['shape', 'code'].includes(node.type)) return
    const candidates = [...canvas.nodes.values()].filter(value => mutable(value) && ['shape', 'code'].includes(value.type))
    mode = {kind: 'connect', stage: existing ? 0 : 1, candidates, id: existing?.id, source: node.id, target: existing?.target || candidates.find(value => value.id !== node.id)?.id || node.id, sourceHandle: existing?.sourceHandle ?? 'right', targetHandle: existing?.targetHandle ?? 'left'}
    root.focus({preventScroll: true})
    describeMode()
    canvas.schedule()
  }
  function connectKey(event) {
    if (event.key === 'Escape') { mode = null; marker.hidden = true; canvas.schedule(); return }
    if (event.key === 'Enter') {
      if (mode.stage < 3) { mode.stage++; describeMode(); canvas.schedule(); return }
      if (mode.source === mode.target && (!mode.sourceHandle || !mode.targetHandle || mode.sourceHandle === mode.targetHandle)) return canvas.announce('Choose different named source and target sides for a self-loop.')
      const {id, source, target, sourceHandle, targetHandle} = mode
      mode = null
      marker.hidden = true
      send('hakushi:change', {op: id ? 'reconnect' : 'connect', edges: [{...(id ? {id} : {}), source, target, sourceHandle, targetHandle}]})
      canvas.schedule()
      return
    }
    const direction = event.key === 'Tab' ? event.shiftKey ? -1 : 1 : ['ArrowLeft', 'ArrowUp'].includes(event.key) ? -1 : ['ArrowRight', 'ArrowDown'].includes(event.key) ? 1 : 0
    if (!direction) return
    const end = mode.stage < 2 ? 'source' : 'target', key = end + (mode.stage % 2 ? 'Handle' : '')
    const choices = mode.stage % 2 ? sides : mode.candidates.map(node => node.id)
    mode[key] = choices[(choices.indexOf(mode[key]) + direction + choices.length) % choices.length]
    describeMode()
    canvas.schedule()
  }
  function editLabel(current) {
    if (!mutable(canvas.nodes.get(current.source)) || !mutable(canvas.nodes.get(current.target))) return
    canvas.editLabel(current.id)
    const input = canvas.labelsEl.querySelector('.hakushi-edge-input')
    input?.addEventListener('keydown', event => {
      if (event.isComposing || event.keyCode === 229) event.stopImmediatePropagation()
    }, true)
  }
  const drawOverlay = canvas.drawOverlay.bind(canvas)
  canvas.drawOverlay = () => {
    drawOverlay()
    let point = null
    if (mode?.kind === 'geometry') {
      const {node, handle, angle} = mode
      if (mode.points) {
        point = {x: mode.points[handle][0], y: mode.points[handle][1]}
        const line = document.createElementNS('http://www.w3.org/2000/svg', 'line')
        line.setAttribute('class', 'hakushi-shape-preview')
        for (const [key, value] of Object.entries({x1: mode.points[0][0], y1: mode.points[0][1], x2: mode.points[1][0], y2: mode.points[1][1]})) line.setAttribute(key, value)
        canvas.overlay.append(line)
      } else {
        const corner = corners[handle], theta = angle * Math.PI / 180
        const x = corner.includes('w') ? -node.width / 2 : corner.includes('e') ? node.width / 2 : 0
        const y = corner === 'rotation' ? -node.height / 2 - 28 : corner.includes('n') ? -node.height / 2 : corner.includes('s') ? node.height / 2 : 0
        point = {x: node.x + node.width / 2 + x * Math.cos(theta) - y * Math.sin(theta), y: node.y + node.height / 2 + x * Math.sin(theta) + y * Math.cos(theta)}
      }
    } else if (mode?.kind === 'connect') {
      const preview = {...mode, path: mode.id ? canvas.edges.get(mode.id)?.path : 'bezier'}
      const geometry = canvas.geometry(preview)
      if (geometry) {
        point = mode.stage < 2 ? geometry.from : geometry.to
        const line = document.createElementNS('http://www.w3.org/2000/svg', 'line')
        line.setAttribute('class', 'hakushi-shape-preview')
        for (const [key, value] of Object.entries({x1: geometry.from.x, y1: geometry.from.y, x2: geometry.to.x, y2: geometry.to.y})) line.setAttribute(key, value)
        canvas.overlay.append(line)
      }
    } else if (cursor && !cursor.node) {
      const view = canvas.edgeViews.get(cursor.id)
      if (view) { view.g.setAttribute('data-keyboard-focus', ''); point = {x: view.box.x + view.box.width / 2, y: view.box.y + view.box.height / 2} }
    }
    for (const [id, view] of canvas.edgeViews) if (id !== cursor?.id || cursor?.node) view.g.removeAttribute('data-keyboard-focus')
    marker.hidden = !point
    if (point) { marker.style.left = `${point.x * canvas.view.zoom + canvas.view.x}px`; marker.style.top = `${point.y * canvas.view.zoom + canvas.view.y}px` }
  }
  const pointerDown = canvas.pointerDown.bind(canvas)
  canvas.pointerDown = event => {
    if (event.target?.closest('.drawing-thought-preview')) return
    if (mode?.kind === 'thought') cancelThought()
    if (spacePending) spacePending.pointer = true
    if (mode?.kind === 'geometry') finishGeometry(false)
    else mode = null
    cursor = null
    marker.hidden = true
    pointerDown(event)
  }
  function help() {
    helpObserver?.disconnect()
    const menu = workspace.querySelector('#file-menu')
    if (!menu) workspace.querySelector('#file-menu-toggle')?.click()
    const reveal = () => {
      const details = workspace.querySelector('#keyboard-shortcuts')
      if (!details) return false
      details.open = true
      details.querySelector('summary').focus()
      details.scrollIntoView({block: 'nearest'})
      return true
    }
    if (!reveal()) {
      helpObserver = new MutationObserver(() => { if (reveal() || !workspace.isConnected) { helpObserver.disconnect(); helpObserver = null } })
      helpObserver.observe(workspace, {childList: true, subtree: true})
    }
  }
  const flush = event => {
    if (mode?.kind === 'geometry') finishGeometry(true)
    if (mode?.kind === 'thought') {
      const committed = finishThought(true)
      if (!committed) event.preventDefault()
      else event.detail?.waiters.push(committed)
    }
  }
  workspace.addEventListener('canvas:flush', flush)
  const focusOut = event => {
    spacePending = null
    if (!mode || root.contains(event.relatedTarget)) return
    if (event.relatedTarget?.closest('[data-zen-toggle]')) return
    if (mode.kind === 'thought') {
      if (!event.relatedTarget && document.hasFocus?.() === false) return
      if (event.relatedTarget?.closest('#save-file, [data-save-copy], #file-menu, #new-canvas, #open-native-file, #empty-open-file, #file-menu-toggle')) return
      cancelThought()
      return
    }
    if (mode.kind === 'geometry') {
      if (event.relatedTarget?.closest('#save-file, [data-save-copy], #file-menu, #file-menu-toggle')) return
      finishGeometry(false)
      canvas.announce('Geometry preview cancelled after leaving the canvas.')
    } else { mode = null; marker.hidden = true; canvas.schedule() }
  }
  root.addEventListener('focusout', focusOut)
  const observer = new MutationObserver(() => {
    if (mode?.kind === 'geometry' && (!canvas.nodes.has(mode.node.id) || !mode.node.el.isConnected || mode.node.locked || canvas.config.readonly)) finishGeometry(false)
  })
  observer.observe(canvas.nodesEl, {childList: true, subtree: true, attributes: true, attributeFilter: ['data-locked']})
  function key(event) {
    if (workspace.codeDraft) return false
    if (event.key === 'Escape' && helpObserver) { helpObserver.disconnect(); helpObserver = null }
    if (event.metaKey || event.ctrlKey || event.altKey) {
      const conflicts = (event.metaKey || event.ctrlKey) && (
        ['z', 'y', 'a', 'c', 'x', 'v', 'd'].includes(event.key.toLowerCase()) ||
        event.shiftKey && ['BracketLeft', 'BracketRight'].includes(event.code)) ||
        event.altKey && event.key.startsWith('Arrow')
      if (mode && conflicts) {
        if (mode.kind === 'thought') cancelThought()
        else if (mode.kind === 'geometry') finishGeometry(false)
        else { mode = null; marker.hidden = true; canvas.schedule() }
      }
      return false
    }
    if (mode) {
      event.preventDefault()
      if (mode.kind === 'thought') {
        if (mode.committing) return true
        if (event.key === 'Escape') cancelThought(true)
        else if (mode.input) mode.input.focus({preventScroll: true})
        else if (event.key.startsWith('Arrow')) {
          mode.preview.classList.remove('drawing-thought-choosing')
          startThoughtText(event.key)
        }
        return true
      }
      if (mode.kind === 'connect') connectKey(event)
      else if (event.key === 'Escape' || event.key === 'Enter') finishGeometry(event.key === 'Enter')
      else if (event.key === 'Tab') { mode.handle = (mode.handle + (event.shiftKey ? -1 : 1) + (mode.points ? 2 : 9)) % (mode.points ? 2 : 9); describeMode(); canvas.schedule() }
      else { const delta = {ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1]}[event.key]; if (delta) moveHandle(...delta, event.shiftKey ? 10 : 1) }
      return true
    }
    if (canvas.gesture) return false
    const endpoint = event.target.closest('.drawing-line-endpoint')
    if (endpoint && event.key.startsWith('Arrow')) {
      geometry()
      if (!mode) return false
      mode.handle = endpoint.dataset.end === 'to' ? 1 : 0
      const delta = {ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1]}[event.key]
      if (delta) { event.preventDefault(); moveHandle(...delta, event.shiftKey ? 10 : 1) }
      return true
    }
    if (event.key === 'Tab') {
      const choices = items(), focused = document.activeElement?.closest('.hakushi-node')?.dataset.id
      // Enter the selected drawing before applying a traversal direction.
      // Canvas order is stable for multi-selection; virtual edge focus wins.
      if (!focused && !cursor && document.activeElement === root) {
        const anchor = choices.find(item => item.node && canvas.selected.has(item.id))
        if (anchor) { event.preventDefault(); focusItem(anchor); return true }
      }
      const index = focused ? choices.findIndex(item => item.node && item.id === focused) : cursor ? choices.findIndex(item => item.node === cursor.node && item.id === cursor.id) : -1
      const next = index + (event.shiftKey ? -1 : 1)
      if (next < 0 || next >= choices.length) {
        if (next < 0 && focused) {
          // Root precedes the nodes in native tab order. Start there so the
          // unhandled Shift+Tab leaves the canvas instead of re-entering it.
          navigating = true
          root.focus({preventScroll: true})
          navigating = false
        }
        if (next >= choices.length && cursor && !cursor.node) {
          const last = choices.findLast(item => item.node)
          if (last) {
            navigating = true
            canvas.nodes.get(last.id).el.focus({preventScroll: true})
            navigating = false
          }
        }
        cursor = null
        return true
      }
      event.preventDefault(); focusItem(choices[next]); return true
    }
    if (event.key === ' ' && !event.shiftKey && (cursor || document.activeElement?.classList.contains('hakushi-node'))) {
      if (!event.repeat) spacePending = {pointer: false}
      return false
    }
    if (event.key.toLowerCase() === 'n' && !event.shiftKey) { event.preventDefault(); thought(); return true }
    if (event.key.toLowerCase() === 'g' && !event.shiftKey) { event.preventDefault(); geometry(); return true }
    if (event.key.toLowerCase() === 'c' && !event.shiftKey) { event.preventDefault(); connect(); return true }
    if (!canvas.tool && ['Enter', 'F2'].includes(event.key) && !document.activeElement?.classList.contains('hakushi-node') && edge()) { event.preventDefault(); editLabel(edge()); return true }
    if (event.key.toLowerCase() === 's' && !event.shiftKey) { event.preventDefault(); workspace.querySelector('#style-toggle')?.click(); return true }
    if (event.key === '?') { event.preventDefault(); help(); return true }
    return false
  }
  const keyUp = event => {
    if (event.key !== ' ' || !spacePending) return
    const pending = spacePending
    spacePending = null
    if (!pending.pointer && !event.isComposing && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault()
      toggleItem()
    }
  }
  root.addEventListener('keyup', keyUp)
  return {key, get active() { return mode !== null }, destroy() {
    if (mode?.kind === 'thought') cancelThought()
    if (mode?.kind === 'geometry') finishGeometry(false)
    workspace.removeEventListener('canvas:flush', flush)
    root.removeEventListener('focusout', focusOut)
    root.removeEventListener('keyup', keyUp)
    observer.disconnect()
    helpObserver?.disconnect()
    marker.remove()
  }}
}
