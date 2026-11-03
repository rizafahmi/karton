const colors = ['none', 'ink', 'gray', 'blue', 'green', 'yellow', 'red', 'violet', 'accent', 'surface']

export function mountConnectorStyles(canvas) {
  const markers = new Map()
  let metadata = {}
  const read = () => {
    metadata = JSON.parse(canvas.root.dataset.connectorStyles || '{}')
    canvas.allDirty = true
    canvas.drawStylePanel()
    canvas.schedule()
  }
  const authored = id => {
    const value = metadata[id]
    return value && typeof value === 'object' && !Array.isArray(value) ? value : {}
  }
  const marker = (edge, view) => {
    if (edge.marker === 'none') return
    const stroke = authored(edge.id).stroke
    const palette = colors.includes(stroke) ? stroke : 'legacy'
    const state = view.g.hasAttribute('data-keyboard-focus') ? 'focus' :
      view.g.hasAttribute('data-ui-selected') ? 'selected' :
      view.g.hasAttribute('data-ui-connected') ? 'connected' :
      view.g.matches(':hover') ? 'hover' : 'normal'
    const key = `${edge.marker}-${palette}-${state}`
    let pair = markers.get(key)
    if (!pair) {
      pair = ['', '-on'].map(suffix => {
        const original = canvas.root.querySelector(`[id="${CSS.escape(canvas.id)}-${edge.marker}${suffix}"]`)
        const clone = original.cloneNode(true)
        clone.id = `${canvas.id}-connector-${key}${suffix}`
        original.parentNode.append(clone)
        return clone
      })
      markers.set(key, pair)
    }
    const line = getComputedStyle(view.line)
    const rootStyle = getComputedStyle(canvas.root)
    const normal = colors.includes(stroke) ? (stroke === 'none' ? 'none' : rootStyle.getPropertyValue(`--hakushi-shape-${stroke}`).trim()) : rootStyle.getPropertyValue('--hakushi-edge').trim()
    pair[0].style.setProperty('--hakushi-edge', normal)
    pair[1].style.setProperty('--hakushi-edge-selected', line.stroke)
    const highlighted = line.stroke !== getComputedStyle(pair[0]).fill
    view.line.setAttribute('marker-end', `url(#${pair[highlighted ? 1 : 0].id})`)
  }
  const drawEdges = canvas.drawEdges.bind(canvas)
  canvas.drawEdges = (...args) => {
    // Variables preserve native selection/hover/forced-colors and the 14px hit path.
    for (const edge of canvas.edges.values()) {
      const view = canvas.edgeViews.get(edge.id)
      if (view) apply(edge, view)
    }
    drawEdges(...args)
    for (const edge of canvas.edges.values()) {
      const view = canvas.edgeViews.get(edge.id)
      if (!view) continue
      apply(edge, view)
      marker(edge, view)
    }
  }
  function apply(edge, view) {
    const style = authored(edge.id)
    view.line.style.transition = 'none'
    view.g.style.setProperty('--hakushi-edge', colors.includes(style.stroke) ? (style.stroke === 'none' ? 'none' : `var(--hakushi-shape-${style.stroke})`) : 'var(--connector-legacy-edge)')
    if ([1, 2, 4].includes(style.width)) view.g.style.setProperty('--hakushi-edge-width', `${style.width}px`)
    else view.g.style.removeProperty('--hakushi-edge-width')
    if (typeof style.dash === 'boolean') view.line.style.strokeDasharray = style.dash ? '6 4' : 'none'
    else view.line.style.removeProperty('stroke-dasharray')
  }

  const observer = new MutationObserver(read)
  observer.observe(canvas.root, {attributes: true, attributeFilter: ['data-connector-styles']})
  const refresh = () => canvas.schedule()
  canvas.root.addEventListener('pointerover', refresh)
  canvas.root.addEventListener('pointerout', refresh)
  read()
  return () => {
    observer.disconnect()
    canvas.root.removeEventListener('pointerover', refresh)
    canvas.root.removeEventListener('pointerout', refresh)
    for (const pair of markers.values()) for (const element of pair) element.remove()
  }
}
