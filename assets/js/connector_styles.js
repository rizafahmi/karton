const colors = ['none', 'ink', 'gray', 'blue', 'green', 'yellow', 'red', 'violet', 'accent', 'surface']
const values = {stroke: colors, width: [1, 2, 4], dash: [false, true]}

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
  const effective = (edge, key) => {
    const value = authored(edge.id)[key]
    return values[key].includes(value) ? value : ({width: 2, dash: edge.animated})[key]
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

  const drawStylePanel = canvas.drawStylePanel.bind(canvas)
  canvas.drawStylePanel = () => {
    const edges = [...canvas.selectedEdges].map(id => canvas.edges.get(id)).filter(Boolean)
    // Mixed node/edge selections retain the ordinary node inspector; edges are not
    // silently edited by node controls. Edge-only multiselection is one command.
    if (!edges.length || canvas.selected.size || canvas.tool || canvas.config.readonly || canvas.cropping) return drawStylePanel()
    const focus = canvas.styleEl?.contains(document.activeElement) ? {key: document.activeElement.dataset.key, value: document.activeElement.dataset.value} : null
    canvas.styleEl?.remove()
    const panel = document.createElement('div')
    panel.className = 'hakushi-style-panel'
    panel.setAttribute('role', 'toolbar')
    panel.setAttribute('aria-label', 'Connector style')
    panel.setAttribute('aria-orientation', 'vertical')
    panel.addEventListener('pointerdown', event => event.stopPropagation())
    const groups = canvas.config.styles.flatMap(kit => kit.groups)
    for (const key of ['stroke', 'width', 'dash']) {
      const definition = groups.find(group => group.key === key)
      const group = document.createElement('div')
      group.className = 'hakushi-style-group'
      group.dataset.kind = definition.kind
      group.setAttribute('role', 'group')
      group.setAttribute('aria-label', definition.label)
      const label = document.createElement('span')
      label.className = 'hakushi-style-label'
      label.setAttribute('aria-hidden', 'true')
      label.textContent = definition.label
      const options = document.createElement('div')
      options.className = 'hakushi-style-options'
      for (const option of definition.options) {
        if (!values[key].includes(option.value)) continue
        const button = document.createElement('button')
        button.type = 'button'
        button.className = 'hakushi-style-option'
        button.dataset.key = key
        button.dataset.value = JSON.stringify(option.value)
        button.setAttribute('aria-label', `${definition.label}: ${option.label}`)
        button.title = option.label
        button.setAttribute('aria-pressed', String(edges.every(edge => effective(edge, key) === option.value)))
        if (key === 'stroke') {
          button.classList.add('hakushi-style-swatch')
          button.dataset.color = option.value
          button.style.setProperty('--hakushi-swatch', option.value === 'none' ? 'transparent' : `var(--hakushi-shape-${option.value})`)
        } else if (key === 'width') {
          button.append(document.createElement('span'))
          button.style.setProperty('--hakushi-style-width', `${option.value}px`)
        } else button.textContent = option.label
        button.addEventListener('click', () => canvas.push('drawing:edge-style', {edges: edges.map(edge => edge.id), key, value: option.value}, reply => {
          if (reply.error) {
            canvas.announce(reply.error)
            const error = document.createElement('p')
            error.className = 'connector-style-error'
            error.setAttribute('role', 'alert')
            error.textContent = reply.error
            panel.querySelector('.connector-style-error')?.remove()
            panel.append(error)
          }
        }))
        options.append(button)
      }
      group.append(label, options)
      panel.append(group)
    }
    canvas.styleEl = panel
    canvas.ui.append(panel)
    if (focus) [...panel.querySelectorAll('button')].find(button => button.dataset.key === focus.key && button.dataset.value === focus.value)?.focus({preventScroll: true})
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
