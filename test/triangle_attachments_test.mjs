import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'

async function moduleAt(path) {
  const source = await readFile(new URL(path, import.meta.url), 'utf8')
  return import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
}
const {Hakushi} = await moduleAt('../deps/hakushi/priv/static/hakushi.esm.js')
const {mountSelfLoops} = await moduleAt('../assets/js/self_loops.js')
const {mountDirectKeyboard} = await moduleAt('../assets/js/direct_keyboard.js')

function style() {
  const values = new Map()
  return {getPropertyValue: key => values.get(key) || '', setProperty(key, value) { values.set(key, value) }, removeProperty(key) { values.delete(key) }}
}
function datasetKey(name) { return name.slice(5).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase()) }
class Element {
  constructor(tag) {
    this.tagName = tag.toUpperCase()
    this.children = []
    this.dataset = {}
    this.attributes = new Map()
    this.style = style()
    this.listeners = new Map()
    this.className = ''
    this.isConnected = true
    this.classList = {
      contains: name => this.className.split(' ').includes(name),
      add: name => { if (!this.classList.contains(name)) this.className = `${this.className} ${name}`.trim() },
      remove: name => { this.className = this.className.split(' ').filter(value => value !== name).join(' ') },
      toggle: (name, active) => { active ? this.classList.add(name) : this.classList.remove(name) },
    }
  }
  setAttribute(name, value) {
    this.attributes.set(name, String(value))
    if (name.startsWith('data-')) this.dataset[datasetKey(name)] = String(value)
    if (name === 'class') this.className = value
    if (name === 'id') this.id = value
  }
  getAttribute(name) { return name.startsWith('data-') ? this.dataset[datasetKey(name)] ?? null : this.attributes.get(name) ?? null }
  hasAttribute(name) { return this.getAttribute(name) !== null }
  removeAttribute(name) { this.attributes.delete(name); if (name.startsWith('data-')) delete this.dataset[datasetKey(name)] }
  toggleAttribute(name, active) { active ? this.setAttribute(name, '') : this.removeAttribute(name) }
  append(...children) { for (const child of children) { child.parentElement = this; this.children.push(child) } }
  prepend(...children) { children.forEach(child => { child.parentElement = this }); this.children.unshift(...children) }
  replaceChildren(...children) { this.children = []; this.append(...children) }
  remove() { if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this) }
  matches(selector) {
    if (selector.startsWith('#')) return this.id === selector.slice(1)
    const tag = selector.match(/^[a-z]+/i)?.[0]
    if (tag && this.tagName !== tag.toUpperCase()) return false
    for (const [, name] of selector.matchAll(/\.([\w-]+)/g)) if (!this.classList.contains(name)) return false
    for (const [, name, value] of selector.matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)) {
      if (!this.hasAttribute(name) || value !== undefined && this.getAttribute(name) !== value) return false
    }
    return true
  }
  querySelectorAll(selector) {
    const direct = selector.startsWith(':scope > ')
    const selectors = selector.replace(':scope > ', '').split(',').map(value => value.trim())
    const children = direct ? this.children : this.children.flatMap(child => [child, ...child.descendants()])
    return children.filter(child => selectors.some(value => child.matches(value)))
  }
  descendants() { return this.children.flatMap(child => [child, ...child.descendants()]) }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null }
  closest(selector) { return selector.split(',').some(value => this.matches(value.trim())) ? this : this.parentElement?.closest(selector) || null }
  contains(child) { return child === this || this.descendants().includes(child) }
  addEventListener(name, fn) { this.listeners.set(name, fn) }
  removeEventListener(name) { this.listeners.delete(name) }
  focus() { document.activeElement = this }
  getBoundingClientRect() { return {x: 0, y: 0, left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0} }
}
function element(tag, attributes = {}) {
  const node = new Element(tag)
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value)
  return node
}
function apply(matrix, point) { return {x: matrix.a * point.x + matrix.c * point.y + matrix.e, y: matrix.b * point.x + matrix.d * point.y + matrix.f} }
function rect(x, y, width, height) { return {x, y, left: x, top: y, width, height, right: x + width, bottom: y + height} }

// A small layout-only DOM: real Hakushi mounts, measures, resolves, and draws edges.
// The fixture exposes SVG points/CTM and CSS percentage positioning like the browser;
// expectations below inspect the drawn connector, never canvas.anchor/geometry.
function editor({width = 320, height = 140, angle = 0, zoom = 1} = {}) {
  globalThis.Element = globalThis.HTMLElement = Element
  globalThis.MutationObserver = globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
  globalThis.requestAnimationFrame = () => 1
  globalThis.cancelAnimationFrame = () => {}
  globalThis.getComputedStyle = node => node.style
  globalThis.CSS = {escape: value => value}
  globalThis.window = {addEventListener() {}, removeEventListener() {}}
  const workspace = element('main', {id: 'workspace'})
  const root = element('div', {id: 'drawing', class: 'hakushi'})
  root.getBoundingClientRect = () => rect(37, 61, 1000, 800)
  workspace.append(root)
  const parts = Object.fromEntries(['viewport', 'world', 'nodes', 'edge-data', 'labels', 'ui', 'svg'].map(name => [name, element(name === 'svg' ? 'svg' : 'div', {id: `drawing-${name}`})]))
  root.append(parts.viewport, parts.world, parts.ui)
  parts.world.append(parts.nodes, parts['edge-data'], parts.labels, parts.svg)
  const hook = element('div', {'data-config': JSON.stringify({controls: false, tools: [], minimap: false, grid: 20, minZoom: 0.1, maxZoom: 4, fit: false, rules: {loops: true}})})
  root.append(hook)
  globalThis.document = {documentElement: element('html'), body: element('body'), activeElement: root, createElement: tag => element(tag), createElementNS: (_, tag) => element(tag), addEventListener() {}, removeEventListener() {}, elementFromPoint: () => null}
  const worldMatrix = () => {
    const values = parts.world.style.transform?.match(/-?\d+(?:\.\d+)?/g)?.map(Number) || [0, 0, 1]
    return {a: values[2], b: 0, c: 0, d: values[2], e: 37 + values[0], f: 61 + values[1]}
  }
  const addShape = (id, kind, x, y, w, h, rotation) => {
    const node = element('div', {class: 'hakushi-node', 'data-id': id, 'data-type': 'shape', 'data-x': x, 'data-y': y, 'data-width': w, 'data-height': h, 'data-resizable': 'true', 'aria-label': id})
    Object.defineProperties(node, {
      offsetWidth: {get: () => parseFloat(node.style.width) || Number(node.dataset.width)},
      offsetHeight: {get: () => parseFloat(node.style.height) || Number(node.dataset.height)},
    })
    const origin = () => {
      const [px, py] = node.style.translate?.match(/-?\d+(?:\.\d+)?/g)?.map(Number) || [x, y]
      return apply(worldMatrix(), {x: px, y: py})
    }
    node.getBoundingClientRect = () => { const p = origin(), z = worldMatrix().a; return rect(p.x, p.y, node.offsetWidth * z, node.offsetHeight * z) }
    const shape = element('div', {class: 'hakushi-shape', 'data-kind': kind, 'data-hakushi-rotate': ''})
    shape.style.setProperty('--hakushi-rotation', `${rotation}deg`)
    const svg = element('svg', {class: 'hakushi-shape-outline'})
    svg.viewBox = {baseVal: {x: 0, y: 0, width: w, height: h}}
    const matrix = () => {
      const z = worldMatrix().a, p = origin(), theta = parseFloat(shape.style.getPropertyValue('--hakushi-rotation')) * Math.PI / 180
      const cos = Math.cos(theta), sin = Math.sin(theta), sx = node.offsetWidth / svg.viewBox.baseVal.width, sy = node.offsetHeight / svg.viewBox.baseVal.height
      const a = z * cos * sx, b = z * sin * sx, c = -z * sin * sy, d = z * cos * sy
      return {a, b, c, d, e: p.x + z * node.offsetWidth / 2 - a * svg.viewBox.baseVal.width / 2 - c * svg.viewBox.baseVal.height / 2, f: p.y + z * node.offsetHeight / 2 - b * svg.viewBox.baseVal.width / 2 - d * svg.viewBox.baseVal.height / 2}
    }
    svg.getScreenCTM = matrix
    const vertices = [{x: w / 2, y: 2}, {x: w - 2, y: h - 2}, {x: 2, y: h - 2}]
    const polygon = element('polygon')
    polygon.points = {numberOfItems: 3, getItem: index => vertices[index]}
    if (kind === 'triangle') svg.append(polygon)
    shape.append(svg)
    for (const side of ['top', 'right', 'bottom', 'left']) {
      const handle = element('span', {class: 'hakushi-handle', 'data-side': side})
      handle.getBoundingClientRect = () => {
        const px = handle.style.getPropertyValue('left'), py = handle.style.getPropertyValue('top')
        const {width: viewWidth, height: viewHeight} = svg.viewBox.baseVal
        const point = {x: px ? parseFloat(px) / 100 * viewWidth : side === 'left' ? 0 : side === 'right' ? viewWidth : viewWidth / 2, y: py ? parseFloat(py) / 100 * viewHeight : side === 'top' ? 0 : side === 'bottom' ? viewHeight : viewHeight / 2}
        const center = apply(matrix(), point), size = 7 * worldMatrix().a
        return rect(center.x - size / 2, center.y - size / 2, size, size)
      }
      shape.append(handle)
    }
    node.append(shape)
    parts.nodes.append(node)
    return {node, shape, svg, vertices, polygon}
  }
  const triangle = addShape('triangle', 'triangle', 80, 90, width, height, angle)
  const peer = addShape('peer', 'rect', 700, 400, 140, 100, 0)
  const standalone = element('div', {class: 'hakushi-node', 'data-id': 'standalone', 'data-type': 'shape-line', 'data-x': 95, 'data-y': 120, 'data-width': 220, 'data-height': 100})
  const lineSvg = element('svg', {class: 'hakushi-shape-line'})
  const line = element('line', {class: 'hakushi-shape-line-stroke', x1: 12, y1: 12, x2: 208, y2: 88, 'marker-end': 'url(#standalone-arrow)'})
  lineSvg.append(line)
  standalone.append(lineSvg)
  parts.nodes.append(standalone)
  const edges = []
  for (const side of ['top', 'right', 'bottom', 'left', null]) for (const source of [true, false]) {
    const edge = {id: `${source ? 'source' : 'target'}-${side}`, source: source ? 'triangle' : 'peer', target: source ? 'peer' : 'triangle', sourceHandle: source ? side : 'left', targetHandle: source ? 'left' : side, path: 'bezier'}
    const data = element('div', Object.fromEntries(Object.entries(edge).filter(([, value]) => value !== null).map(([key, value]) => [`data-${key.replace(/[A-Z]/g, letter => `-${letter.toLowerCase()}`)}`, value])))
    parts['edge-data'].append(data)
    edges.push(edge)
  }
  const owner = {el: hook, pushEventTo() {}, handleEvent() {}}
  Hakushi.mounted.call(owner)
  const canvas = owner.canvas
  mountSelfLoops(canvas)
  canvas.setView({x: -23, y: 41, zoom})
  canvas.render()
  return {canvas, triangle, peer, edges, worldMatrix, workspace, standalone, line}
}

function distanceToSegment(point, a, b) {
  const dx = b.x - a.x, dy = b.y - a.y
  const fraction = Math.max(0, Math.min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)))
  return {distance: Math.hypot(point.x - a.x - dx * fraction, point.y - a.y - dy * fraction), fraction}
}
function cross(a, b, point) { return (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x) }
function drawnEnds(path, matrix) {
  const numbers = path.getAttribute('d').match(/-?\d+(?:\.\d+)?(?:e[+-]?\d+)?/gi).map(Number)
  return {from: apply(matrix, {x: numbers[0], y: numbers[1]}), fromControl: apply(matrix, {x: numbers[2], y: numbers[3]}), to: apply(matrix, {x: numbers.at(-2), y: numbers.at(-1)}), toControl: apply(matrix, {x: numbers.at(-4), y: numbers.at(-3)})}
}
function assertAttachment(editor, edge, path, tolerance = 0.16) {
  const {triangle, worldMatrix} = editor
  const outline = triangle.vertices.map(point => apply(triangle.svg.getScreenCTM(), point))
  const source = edge.source === 'triangle', side = source ? edge.sourceHandle : edge.targetHandle
  const ends = drawnEnds(path, worldMatrix()), point = source ? ends.from : ends.to, control = source ? ends.fromControl : ends.toControl
  const distances = outline.map((a, index) => distanceToSegment(point, a, outline[(index + 1) % 3]).distance)
  assert.ok(Math.min(...distances) < tolerance, `${edge.id} misses the drawn triangle by ${Math.min(...distances)}px`)
  if (side === 'top') assert.ok(Math.hypot(point.x - outline[0].x, point.y - outline[0].y) < tolerance)
  else if (side !== null) {
    const index = {right: 0, bottom: 1, left: 2}[side]
    assert.ok(Math.abs(distanceToSegment(point, outline[index], outline[(index + 1) % 3]).fraction - 0.5) < 0.002, `${side} must stay at its outline side midpoint`)
    const a = outline[index], b = outline[(index + 1) % 3]
    assert.ok(cross(a, b, {x: a.x + control.x - point.x, y: a.y + control.y - point.y}) < 0, `${edge.id} has an inward tangent`)
  } else {
    const handles = [outline[0], ...outline.map((a, index) => ({x: (a.x + outline[(index + 1) % 3].x) / 2, y: (a.y + outline[(index + 1) % 3].y) / 2}))]
    const box = editor.peer.svg.viewBox.baseVal, peerCenter = apply(editor.peer.svg.getScreenCTM(), {x: box.width / 2, y: box.height / 2})
    const nearest = handles.reduce((best, candidate) => Math.hypot(candidate.x - peerCenter.x, candidate.y - peerCenter.y) < Math.hypot(best.x - peerCenter.x, best.y - peerCenter.y) ? candidate : best)
    assert.ok(Math.hypot(point.x - nearest.x, point.y - nearest.y) < tolerance, 'automatic bindings retain nearest-outline-handle selection')
  }
  const departure = {x: point.x + (control.x - point.x) * 0.02, y: point.y + (control.y - point.y) * 0.02}
  assert.ok(outline.some((a, index) => cross(a, outline[(index + 1) % 3], departure) < 0), `${edge.id} routes inward from its triangle attachment`)
}

test('named and automatic source/target connections meet the rendered triangle across rotation and non-square sizes', () => {
  for (const [width, height, angle, zoom] of [[320, 140, 0, 1], [400, 300, -15, 1.6], [160, 310, 90, 0.7], [340, 90, 165, 1], [170, 180, 270, 1.2]]) {
    const current = editor({width, height, angle, zoom})
    for (const edge of current.edges) {
      const view = current.canvas.edgeViews.get(edge.id)
      assertAttachment(current, edge, view.line)
      assert.equal(view.hit.getAttribute('d'), view.line.getAttribute('d'))
      const handleId = edge.source === 'triangle' ? edge.sourceHandle : edge.targetHandle
      if (handleId !== null) {
        const handle = current.triangle.shape.querySelector(`[data-handle="${handleId}"]`)
        const bounds = handle.getBoundingClientRect()
        const ends = drawnEnds(view.line, current.worldMatrix())
        const point = edge.source === 'triangle' ? ends.from : ends.to
        assert.ok(Math.hypot(point.x - bounds.left - bounds.width / 2, point.y - bounds.top - bounds.height / 2) < 0.16)
        assert.equal(handle.dataset.side, handleId)
      }
      current.canvas.pending = {source: {node: edge.source, handle: edge.sourceHandle}, target: {node: edge.target, handle: edge.targetHandle}}
      current.canvas.drawOverlay()
      assertAttachment(current, edge, current.canvas.overlay.querySelector('.hakushi-edge-pending'))
      current.canvas.pending = null
      if (handleId !== null) {
        const fromNode = current.canvas.nodes.get(edge.source), fromHandle = fromNode.handles.find(handle => handle.id === edge.sourceHandle)
        current.canvas.gesture = {kind: 'connect', from: {node: edge.source, handle: edge.sourceHandle}, fromHandle, at: {x: 700, y: 400}, target: {end: {node: edge.target, handle: edge.targetHandle}}}
        current.canvas.drawOverlay()
        assertAttachment(current, edge, current.canvas.overlay.querySelector('.hakushi-edge-pending'))
        current.canvas.gesture = null
      }
    }
  }
})

test('live resize uses the displayed SVG mapping, then a new polygon patch and cancellation remeasure the same handles', () => {
  const current = editor({angle: -15, zoom: 1.3})
  const {canvas, triangle} = current, node = canvas.nodes.get('triangle')
  node.width = 470; node.height = 95; node.x += 24; node.y -= 13
  canvas.decorate(node)
  canvas.measureHandles(node)
  canvas.touchNode(node.id)
  canvas.render()
  for (const edge of current.edges) assertAttachment(current, edge, canvas.edgeViews.get(edge.id).line)
  triangle.svg.viewBox.baseVal.width = 470
  triangle.svg.viewBox.baseVal.height = 95
  triangle.vertices.splice(0, 3, {x: 235, y: 1}, {x: 469, y: 94}, {x: 1, y: 94})
  canvas.measureHandles(node)
  canvas.touchNode(node.id)
  canvas.render()
  for (const edge of current.edges) assertAttachment(current, edge, canvas.edgeViews.get(edge.id).line)
  node.width = 320; node.height = 140
  canvas.decorate(node)
  canvas.measureHandles(node)
  canvas.touchNode(node.id)
  canvas.render()
  for (const edge of current.edges) assertAttachment(current, edge, canvas.edgeViews.get(edge.id).line)
})

test('keyboard resize/rotation previews and Escape keep attached endpoints aligned without changing side bindings', () => {
  const current = editor({angle: -15, zoom: 1.3})
  const {canvas, triangle} = current, node = canvas.nodes.get('triangle')
  canvas.selected.add(node.id)
  canvas.decorate(node)
  triangle.node.focus()
  const keyboard = mountDirectKeyboard(canvas)
  const key = value => keyboard.key({key: value, target: document.activeElement, shiftKey: false, preventDefault() {}})
  key('g'); key('ArrowRight'); key('ArrowDown')
  canvas.render()
  for (const edge of current.edges) assertAttachment(current, edge, canvas.edgeViews.get(edge.id).line)
  key('Escape')
  canvas.render()
  assert.equal(node.width, 320)
  assert.equal(node.height, 140)
  key('g')
  keyboard.key({key: 'Tab', shiftKey: true, target: document.activeElement, preventDefault() {}})
  key('ArrowRight')
  canvas.render()
  for (const edge of current.edges) assertAttachment(current, edge, canvas.edgeViews.get(edge.id).line)
  key('Escape')
  canvas.render()
  assert.equal(triangle.shape.style.getPropertyValue('--hakushi-rotation'), '-15deg')
  for (const edge of current.edges) assertAttachment(current, edge, canvas.edgeViews.get(edge.id).line)
  assert.deepEqual(node.handles.map(handle => handle.id), ['top', 'right', 'bottom', 'left'])
  keyboard.destroy()
})

test('mixed triangle and standalone-arrow mounting preserves free endpoints without acquiring connection handles', () => {
  const current = editor({angle: -15, zoom: 1.3})
  const {canvas, standalone, line} = current
  const endpoints = () => [Number(line.getAttribute('x1')), Number(line.getAttribute('y1')), Number(line.getAttribute('x2')), Number(line.getAttribute('y2'))]
  const original = endpoints(), originalEdges = canvas.edges.size
  const node = canvas.nodes.get('standalone')
  canvas.measureHandles(node)
  canvas.decorate(node)
  canvas.render()
  assert.deepEqual(endpoints(), original)
  assert.equal(line.getAttribute('marker-end'), 'url(#standalone-arrow)')
  assert.deepEqual(node.handles, [])
  assert.equal(standalone.querySelector('.hakushi-handle'), null)
  assert.equal(canvas.edges.size, originalEdges)
  for (const edge of current.edges) assertAttachment(current, edge, canvas.edgeViews.get(edge.id).line)
})
