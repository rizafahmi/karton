const colors = ['none', 'ink', 'gray', 'blue', 'green', 'yellow', 'red', 'violet', 'accent', 'surface']
const encode = value => JSON.stringify(value)
const parse = value => { try { return JSON.parse(value || '{}') } catch { return {} } }
const element = (tag, className, text) => {
  const el = document.createElement(tag)
  el.className = className
  if (text !== undefined) el.textContent = text
  return el
}

export function mountStyleInspector(canvas) {
  const original = canvas.drawStylePanel
  canvas.styleEl?.remove()
  const panel = element('section', 'hakushi-style-panel style-inspector')
  panel.id = `${canvas.id}-style-inspector`
  panel.setAttribute('aria-label', 'Style inspector')
  const header = element('div', 'style-inspector-header')
  const title = element('h2', 'style-inspector-title', 'Style')
  const close = element('button', 'style-inspector-close', 'Close')
  close.type = 'button'
  close.setAttribute('aria-label', 'Close Style inspector')
  close.addEventListener('click', () => panel.dispatchEvent(new CustomEvent('canvas:close-style', {bubbles: true})))
  header.append(title, close)
  const body = element('div', 'style-inspector-body')
  const message = element('p', 'style-inspector-message')
  const error = element('p', 'style-inspector-error')
  error.setAttribute('role', 'alert')
  error.hidden = true
  panel.append(header, message, body, error)
  panel.addEventListener('pointerdown', event => event.stopPropagation())
  canvas.ui.append(panel)
  canvas.styleEl = panel
  let identity = '', schema = '', controls = [], disposed = false
  const workspace = canvas.root.closest('.canvas-workspace')

  function snapshot() {
    const nodes = [...canvas.selected].map(id => canvas.nodes.get(id)).filter(node => node && !canvas.gone.has(node.id))
    const edges = [...canvas.selectedEdges].map(id => canvas.edges.get(id)).filter(Boolean)
    const connector = !nodes.length && edges.length > 0
    const kits = canvas.config.styles || []
    const kit = kits.find(kit => nodes.length ? nodes.every(node => kit.types.includes(node.type)) : kit.groups.some(group => group.key === 'stroke')) ||
      (nodes.length && nodes.every(node => ['shape', 'shape-line', 'code'].includes(node.type)) ? {groups: [...new Map(kits.flatMap(kit => kit.groups).filter(group => group.kind !== 'action').map(group => [group.key, group])).values()]} : null)
    const styles = nodes.map(node => {
      const shape = node.el.querySelector('[data-hakushi-style]')
      const style = parse(shape?.dataset.hakushiStyle)
      if (node.type === 'shape') {
        const kind = shape?.dataset.kind
        // Native renderers supply effective styles; these fallbacks also cover
        // sparse older DOM without writing defaults into the document or DOM.
        const defaults = {fill: kind === 'text' ? 'none' : 'blue', stroke: kind === 'text' ? 'none' : 'blue', width: 2, dash: false, radius: kind === 'text' ? 0 : 8, size: 'm', align: kind === 'text' ? 'left' : 'center'}
        const keys = kind === 'text' ? ['fill', 'size', 'align'] : ['fill', 'stroke', 'width', 'dash', 'size', 'align', ...(kind === 'rect' ? ['radius'] : [])]
        return Object.fromEntries([...keys.map(key => [key, style[key] ?? defaults[key]]), ['font', node.el.querySelector('.drawing-typography[data-drawing-font]')?.dataset.drawingFont || workspace?.dataset.drawingFont || 'sans']])
      }
      if (node.type === 'shape-line') return {stroke: style.stroke ?? 'ink', width: style.width ?? 2, dash: style.dash ?? false, arrow: style.arrow ?? 'end'}
      if (node.type === 'code') {
        const code = node.el.querySelector('[data-code-node]')
        return {fill: style.fill ?? 'none', stroke: style.stroke ?? 'ink', width: style.width ?? 2, dash: style.dash ?? false, radius: style.radius ?? 0, size: code?.dataset.codeSize || style.size || 'm'}
      }
      return style
    })
    const metadata = parse(canvas.root.dataset.connectorStyles)
    const edgeStyles = edges.map(edge => {
      const style = metadata[edge.id] || {}
      return {stroke: colors.includes(style.stroke) ? style.stroke : undefined, width: [1, 2, 4].includes(style.width) ? style.width : 2, dash: typeof style.dash === 'boolean' ? style.dash : !!edge.animated}
    })
    const values = connector ? edgeStyles : styles
    const groups = (kit?.groups || []).filter(group => connector ? ['stroke', 'width', 'dash'].includes(group.key) : group.kind === 'action' ? nodes.length === 1 : values.length && values.every(style => Object.hasOwn(style, group.key)))
    const order = ['fill', 'stroke', 'width', 'dash', 'radius', 'arrow', 'font', 'size', 'align']
    groups.sort((a, b) => (order.indexOf(a.key) < 0 ? order.length : order.indexOf(a.key)) - (order.indexOf(b.key) < 0 ? order.length : order.indexOf(b.key)))
    const blocked = canvas.config.readonly ? 'This canvas is read-only.' : workspace?.codeDraft ? 'Finish or cancel the code draft before changing styles.' : canvas.cropping ? 'Finish cropping before changing styles.' : canvas.tool ? 'Finish the active drawing tool to change selection styles.' : nodes.some(node => node.locked) ? 'Unlock the selected objects before changing styles.' : ''
    return {nodes, edges, connector, values, groups, blocked, id: encode([[...canvas.selected].sort(), [...canvas.selectedEdges].sort()])}
  }

  function setPalette(control, open, focus = false) {
    control.palette.hidden = !open
    control.trigger.setAttribute('aria-expanded', String(open))
    if (focus) control.trigger.focus({preventScroll: true})
  }
  panel.addEventListener('keydown', event => {
    if (event.key !== 'Escape' || event.isComposing) return
    const open = controls.find(control => control.palette && !control.palette.hidden)
    if (open) {
      event.preventDefault()
      event.stopPropagation()
      setPalette(open, false, true)
    }
  })

  function commit(id, group, value) {
    const state = snapshot()
    if (disposed || state.id !== id || state.blocked || !state.groups.some(candidate => candidate.key === group.key)) return
    error.hidden = true
    const reply = result => {
      if (!disposed && identity === id && result?.error) {
        error.textContent = result.error
        error.hidden = false
      }
    }
    if (group.kind === 'action') canvas.styleAction(group.key, state.nodes[0])
    else if (state.connector) canvas.push('drawing:edge-style', {edges: state.edges.map(edge => edge.id), key: group.key, value}, reply)
    else canvas.push('hakushi:edit', {nodes: state.nodes.map(node => node.id), action: 'style', style: {[group.key]: value}}, reply)
  }

  function build(state) {
    body.replaceChildren()
    controls = []
    const sections = new Map()
    for (const group of state.groups) {
      const category = ['font', 'size', 'align'].includes(group.key) ? 'Text' : 'Appearance'
      let section = sections.get(category)
      if (!section) {
        section = element('section', 'style-inspector-section')
        section.append(element('h3', 'style-inspector-heading', category))
        sections.set(category, section)
        body.append(section)
      }
      const row = element('div', 'style-inspector-row')
      const label = element('label', 'style-inspector-label', group.label)
      const holder = element('div', 'style-inspector-control')
      const control = {group, buttons: []}
      const controlId = `${canvas.id}-inspector-${group.key}`
      label.htmlFor = controlId
      const action = value => commit(state.id, group, value)
      if (group.kind === 'color') {
        const trigger = element('button', 'style-color-trigger')
        trigger.type = 'button'
        trigger.id = controlId
        trigger.dataset.key = group.key
        trigger.setAttribute('aria-controls', `${controlId}-palette`)
        const chip = element('span', 'style-color-chip')
        chip.setAttribute('aria-hidden', 'true')
        const name = element('span', 'style-color-name')
        trigger.append(chip, name)
        const palette = element('div', 'style-color-palette')
        palette.id = `${controlId}-palette`
        palette.hidden = true
        control.trigger = trigger; control.palette = palette; control.chip = chip; control.name = name
        trigger.setAttribute('aria-expanded', 'false')
        trigger.addEventListener('click', () => {
          for (const other of controls) if (other.palette && other !== control) setPalette(other, false)
          setPalette(control, palette.hidden)
        })
        for (const option of group.options) {
          const button = element('button', 'style-color-option')
          button.type = 'button'
          button.dataset.key = group.key
          button.dataset.value = encode(option.value)
          button.dataset.color = option.value
          button.setAttribute('aria-label', `${group.label}: ${option.label}`)
          const swatch = element('span', 'style-color-chip')
          swatch.dataset.color = option.value
          swatch.setAttribute('aria-hidden', 'true')
          swatch.style.setProperty('--hakushi-swatch', option.value === 'none' ? 'transparent' : `var(--hakushi-shape-${option.value})`)
          button.append(swatch, element('span', '', option.label))
          button.addEventListener('click', () => action(option.value))
          control.buttons.push(button)
          palette.append(button)
        }
        holder.append(trigger, palette)
      } else if (group.key === 'size') {
        const segments = element('div', 'style-inspector-segments')
        segments.setAttribute('role', 'group')
        segments.setAttribute('aria-label', group.label)
        label.removeAttribute('for')
        for (const option of group.options) {
          const button = element('button', 'style-inspector-option', option.label)
          button.type = 'button'; button.dataset.key = group.key; button.dataset.value = encode(option.value)
          button.setAttribute('aria-label', `${group.label}: ${option.label}`)
          button.addEventListener('click', () => action(option.value))
          segments.append(button); control.buttons.push(button)
        }
        control.mixedLabel = element('span', 'style-inspector-message', 'Mixed')
        control.mixedLabel.hidden = true
        holder.append(segments, control.mixedLabel)
      } else if (group.kind === 'action') {
        const button = element('button', 'style-inspector-option', group.label)
        button.type = 'button'; button.id = controlId; button.dataset.key = group.key
        button.addEventListener('click', () => action())
        holder.append(button); control.input = button
      } else if (group.kind === 'text') {
        const input = element('input', 'style-inspector-select')
        input.type = 'text'; input.id = controlId; input.dataset.key = group.key
        input.addEventListener('change', () => action(input.value))
        holder.append(input); control.input = input
      } else {
        const select = element('select', 'style-inspector-select')
        select.id = controlId; select.dataset.key = group.key
        const sentinel = element('option', '', 'Mixed')
        sentinel.value = '__mixed__'; sentinel.disabled = true
        select.append(sentinel)
        const legacy = element('option', '', 'Default')
        legacy.value = '__default__'; legacy.disabled = true
        select.append(legacy)
        for (const option of group.options) {
          const item = element('option', '', group.key === 'arrow' ? ({end: 'End', both: 'Both ends', none: 'None'})[option.value] : option.label)
          item.value = encode(option.value)
          select.append(item)
        }
        select.addEventListener('change', () => {
          const option = group.options.find(option => encode(option.value) === select.value)
          if (option) action(option.value)
        })
        holder.append(select); control.input = select
      }
      row.append(label, holder)
      section.append(row)
      controls.push(control)
    }
  }

  canvas.drawStylePanel = () => {
    if (disposed) return
    const state = snapshot()
    const nextSchema = encode(state.groups)
    const changed = identity !== state.id || schema !== nextSchema
    if (changed) {
      identity = state.id; schema = nextSchema
      error.hidden = true
      build(state)
    }
    const node = state.nodes[0]
    const kind = node?.type === 'code' ? 'code' : node?.type === 'shape-line' ? 'line' : node?.el.querySelector('[data-hakushi-style]')?.dataset.kind
    const names = {code: 'Code block', rect: 'Rectangle', text: 'Text', line: 'Line', ellipse: 'Ellipse', diamond: 'Diamond', triangle: 'Triangle'}
    title.textContent = state.nodes.length > 1 ? `${state.nodes.length} objects` : node ? names[kind] || 'Object' : state.edges.length > 1 ? `${state.edges.length} connections` : state.edges.length ? 'Connection' : 'Style'
    message.textContent = state.blocked || (!state.nodes.length && !state.edges.length ? 'Select an object or connection to inspect its style.' : !state.groups.length ? 'No shared style controls for this selection.' : '')
    if (state.nodes.length && state.edges.length) message.textContent += `${message.textContent ? ' ' : ''}Only objects will change; connections remain unchanged.`
    message.hidden = !message.textContent
    for (const control of controls) {
      const {group} = control
      const values = state.values.map(style => style[group.key])
      const mixed = values.some(value => value !== values[0])
      const value = mixed ? null : values[0]
      if (control.mixedLabel) control.mixedLabel.hidden = !mixed
      for (const button of control.buttons) {
        button.disabled = !!state.blocked
        button.setAttribute('aria-pressed', String(!mixed && button.dataset.value === encode(value)))
      }
      if (control.trigger) {
        control.trigger.disabled = !!state.blocked
        control.name.textContent = mixed ? 'Mixed' : group.options.find(option => option.value === value)?.label || 'Default'
        control.chip.dataset.color = mixed ? 'mixed' : value ?? 'default'
        control.chip.style.setProperty('--hakushi-swatch', colors.includes(value) && value !== 'none' ? `var(--hakushi-shape-${value})` : 'transparent')
      }
      if (control.input) {
        control.input.disabled = !!state.blocked
        // Keep the actual select/input node and its native popup/editing intact
        // across measurement and LiveView patches of the same selection.
        if (document.activeElement !== control.input || changed) {
          control.input.value = group.kind === 'text' ? (mixed ? '' : value ?? '') : mixed ? '__mixed__' : value === undefined ? '__default__' : encode(value)
        }
      }
    }
  }
  const observer = new MutationObserver(records => {
    if (records.some(record => record.attributeName === 'data-style-open') && workspace?.dataset.styleOpen !== 'true') {
      for (const control of controls) if (control.palette) setPalette(control, false)
    }
    canvas.drawStylePanel()
  })
  observer.observe(canvas.root, {attributes: true, attributeFilter: ['data-connector-styles']})
  if (workspace) observer.observe(workspace, {attributes: true, attributeFilter: ['data-drawing-font', 'data-style-open']})
  canvas.drawStylePanel()
  return () => {
    disposed = true
    observer.disconnect()
    panel.remove()
    if (canvas.styleEl === panel) canvas.styleEl = null
    canvas.drawStylePanel = original
  }
}
