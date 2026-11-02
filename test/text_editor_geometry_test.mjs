import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'

async function moduleAt(path) {
  const source = await readFile(new URL(path, import.meta.url), 'utf8')
  return import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
}
const {Hakushi} = await moduleAt('../deps/hakushi/priv/static/hakushi.esm.js')
const {mountTextEditorGeometry} = await moduleAt('../assets/js/text_editor_geometry.js')
const {mountRotationGuides} = await moduleAt('../assets/js/rotation_guides.js')

function style() {
  const values = new Map()
  return {height: '', getPropertyValue: key => values.get(key) || '', setProperty(key, value) { values.set(key, value) }, removeProperty(key) { values.delete(key) }}
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
    this.innerText = ''
    this.scrollHeight = 80
    this.isConnected = true
    this.classList = {
      contains: name => this.className.split(' ').includes(name),
      add: name => { if (!this.classList.contains(name)) this.className = `${this.className} ${name}`.trim() },
      remove: name => { this.className = this.className.split(' ').filter(value => value !== name).join(' ') },
      toggle: (name, active) => { active ? this.classList.add(name) : this.classList.remove(name) },
    }
  }
  set textContent(value) { this.innerText = value }
  get textContent() { return this.innerText }
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
  remove() { if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this); this.isConnected = false }
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
  descendants() { return this.children.flatMap(child => [child, ...child.descendants()]) }
  querySelectorAll(selector) {
    const direct = selector.startsWith(':scope > ')
    const selectors = selector.replace(':scope > ', '').split(',').map(value => value.trim())
    return (direct ? this.children : this.descendants()).filter(child => selectors.some(value => child.matches(value)))
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null }
  closest(selector) { return selector.split(',').some(value => this.matches(value.trim())) ? this : this.parentElement?.closest(selector) || null }
  contains(child) { return child === this || this.descendants().includes(child) }
  addEventListener(name, fn, options = false) {
    const capture = options === true || options.capture === true
    const listeners = this.listeners.get(name) || []
    listeners.push({fn, capture})
    this.listeners.set(name, listeners)
  }
  removeEventListener(name, fn, options = false) {
    const capture = options === true || options.capture === true
    this.listeners.set(name, (this.listeners.get(name) || []).filter(listener => listener.fn !== fn || listener.capture !== capture))
  }
  dispatch(name, properties = {}) {
    const event = {target: this, stopPropagation() {}, preventDefault() {}, ...properties}
    // Native finish is registered first, but target capture still precedes target bubble.
    const listeners = [...(this.listeners.get(name) || [])]
    for (const capture of [true, false]) for (const listener of listeners) {
      if (listener.capture === capture) listener.fn(event)
    }
  }
  focus() { document.activeElement = this }
  getBoundingClientRect() { return rect(0, 0, 0, 0) }
}
function element(tag, attributes = {}) {
  const node = new Element(tag)
  for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value)
  return node
}
function rect(x, y, width, height) { return {x, y, left: x, top: y, width, height, right: x + width, bottom: y + height} }

// Only layout and event delivery are supplied here. Hakushi owns editor creation,
// geometry measurement, edge invalidation, native finish and emitted commands.
function fixture({own = false, inlineHeight = '80.00px', initialScrollHeight = 80} = {}) {
  globalThis.Element = globalThis.HTMLElement = Element
  globalThis.MutationObserver = globalThis.ResizeObserver = class { observe() {} unobserve() {} disconnect() {} }
  let frames = 0
  globalThis.requestAnimationFrame = () => ++frames
  globalThis.cancelAnimationFrame = () => {}
  globalThis.getComputedStyle = node => node.style
  globalThis.CSS = {escape: value => value}
  globalThis.window = {addEventListener() {}, removeEventListener() {}}
  globalThis.getSelection = () => ({removeAllRanges() {}, addRange() {}})
  globalThis.document = {
    documentElement: element('html'), body: element('body'), activeElement: null,
    createElement: tag => { const node = element(tag); node.scrollHeight = initialScrollHeight; return node },
    createElementNS: (_, tag) => element(tag), createRange: () => ({selectNodeContents() {}}),
    addEventListener() {}, removeEventListener() {}, elementFromPoint: () => null,
  }
  const root = element('div', {id: 'drawing', class: 'hakushi'})
  root.getBoundingClientRect = () => rect(0, 0, 1000, 800)
  const parts = Object.fromEntries(['viewport', 'world', 'nodes', 'edge-data', 'labels', 'ui', 'svg'].map(name => [name, element(name === 'svg' ? 'svg' : 'div', {id: `drawing-${name}`})]))
  root.append(parts.viewport, parts.world, parts.ui)
  parts.world.append(parts.nodes, parts['edge-data'], parts.labels, parts.svg)
  const hook = element('div', {'data-config': JSON.stringify({controls: false, tools: [], minimap: false, grid: 20, minZoom: 0.1, maxZoom: 4, fit: false})})
  root.append(hook)
  const shape = element('div', {class: 'hakushi-node', 'data-id': 'shape', 'data-type': 'shape', 'data-x': 40, 'data-y': 60, 'data-width': 200, 'data-height': 80, 'data-resizable': 'true'})
  shape.style.height = inlineHeight
  Object.defineProperties(shape, {
    offsetWidth: {get: () => 200},
    offsetHeight: {get: () => parseFloat(shape.style.height) || 80},
  })
  shape.getBoundingClientRect = () => rect(40, 60, shape.offsetWidth, shape.offsetHeight)
  const rotated = element('div', {'data-hakushi-rotate': ''})
  rotated.style.setProperty('--hakushi-rotation', '-27deg')
  const text = element('div', {'data-hakushi-text': 'Original', ...(own ? {'data-hakushi-text-own': ''} : {})})
  Object.assign(text, {offsetLeft: 10, offsetTop: 8, offsetWidth: 180, offsetHeight: 24})
  const handle = element('span', {class: 'hakushi-handle', 'data-handle': 'bottom', 'data-side': 'bottom'})
  handle.getBoundingClientRect = () => rect(136, 60 + shape.offsetHeight - 4, 8, 8)
  rotated.append(text, handle)
  shape.append(rotated)
  parts.nodes.append(shape)
  parts['edge-data'].append(element('div', {'data-id': 'connection', 'data-source': 'shape', 'data-source-handle': 'bottom', 'data-target': 'shape', 'data-target-handle': 'bottom'}))
  const commands = [], baselines = []
  const owner = {
    el: hook, handleEvent() {},
    pushEventTo(_target, name, payload, reply) {
      commands.push({name, payload})
      baselines.push({height: owner.canvas.nodes.get('shape').height, style: shape.style.height})
      // A synchronous successful server reply exercises native y.height comparison.
      reply?.({})
    },
  }
  Hakushi.mounted.call(owner)
  const canvas = owner.canvas, node = canvas.nodes.get('shape')
  canvas.selected.add(node.id)
  mountRotationGuides(canvas)
  canvas.decorate(node)
  // Native initial decoration sets fixed dimensions; preserve the style present
  // at edit entry, rather than the markup's pre-mount representation.
  shape.style.height = inlineHeight
  canvas.editText(node)
  const editor = parts.labels.querySelector('.hakushi-text-editor')
  mountTextEditorGeometry(canvas, node, editor)
  const resetInvalidation = () => { canvas.dirty.clear(); canvas.frame = 0; node.measured = false }
  const input = (value, height) => { editor.innerText = value; editor.scrollHeight = height; editor.dispatch('input') }
  return {canvas, node, shape, rotated, text, editor, commands, baselines, input, resetInvalidation, frames: () => frames}
}

function assertBaseline(current, inlineHeight = '80.00px') {
  assert.equal(current.node.height, 80)
  assert.equal(current.shape.style.height, inlineHeight)
  assert.equal(current.node.handles[0].y, 80)
  assert.equal(current.rotated.style.getPropertyValue('--hakushi-rotation'), '-27deg')
  assert.equal(current.editor.style.rotate, '-27deg')
}

test('live multiline preview grows and shrinks to its original floor, remeasuring handles and invalidating connections without commands', () => {
  const current = fixture()
  const {canvas, node, shape, editor, commands} = current
  current.resetInvalidation()
  const version = canvas.layoutVersion, frames = current.frames()
  current.input('One\nTwo\nThree\nFour', 153.2)
  assert.equal(node.height, 154)
  assert.equal(shape.style.height, '154px')
  assert.equal(node.measured, true)
  assert.equal(node.handles[0].y, 154)
  assert.ok(canvas.dirty.has('connection'))
  assert.ok(canvas.layoutVersion > version)
  assert.ok(current.frames() > frames)
  assert.deepEqual(commands, [])
  assert.equal(editor.style.rotate, '-27deg')
  current.input('One\nTwo\nThree', 112)
  assert.equal(node.height, 112)
  assert.equal(node.handles[0].y, 112)
  current.input('One', 24)
  assert.equal(node.height, 80)
  assert.equal(shape.style.height, '80px')
  assert.equal(node.handles[0].y, 80)
  assert.deepEqual(commands, [])
})

test('opening overflowing text previews immediately without a persistence command', () => {
  const current = fixture({initialScrollHeight: 135.1})
  assert.equal(current.node.height, 136)
  assert.equal(current.node.handles[0].y, 136)
  assert.deepEqual(current.commands, [])
})

test('Escape cancels growth and restores the exact original inline height, including an absent inline value', () => {
  for (const inlineHeight of ['80.00px', '']) {
    const current = fixture({inlineHeight})
    current.input('Changed\nText', 175)
    current.resetInvalidation()
    current.editor.dispatch('keydown', {key: 'Escape'})
    assertBaseline(current, inlineHeight)
    assert.equal(current.editor.isConnected, false)
    assert.equal(current.text.style.visibility, '')
    assert.ok(current.canvas.dirty.has('connection'))
    assert.deepEqual(current.commands, [])
    current.editor.dispatch('blur')
    current.input('Late input', 300)
    assertBaseline(current, inlineHeight)
    assert.deepEqual(current.commands, [])
  }
})

for (const finish of ['Meta+Enter', 'Control+Enter', 'blur']) {
  test(`${finish} restores baseline before native text commit and emits the grown move on a synchronous reply`, () => {
    const current = fixture()
    current.input('Changed\nMultiline\nText', 174.2)
    assert.equal(current.node.height, 175)
    assert.deepEqual(current.commands, [])
    if (finish === 'blur') current.editor.dispatch('blur')
    else current.editor.dispatch('keydown', {key: 'Enter', metaKey: finish === 'Meta+Enter', ctrlKey: finish === 'Control+Enter'})
    assertBaseline(current)
    assert.deepEqual(current.baselines, [{height: 80, style: '80.00px'}, {height: 80, style: '80.00px'}])
    assert.deepEqual(current.commands, [
      {name: 'hakushi:edit', payload: {node: 'shape', action: 'text', value: 'Changed\nMultiline\nText'}},
      {name: 'hakushi:change', payload: {op: 'move', nodes: [{id: 'shape', x: 40, y: 60, width: 200, height: 175}]}},
    ])
    assert.equal(current.editor.isConnected, false)
    current.editor.dispatch('blur')
    assert.equal(current.commands.length, 2)
  })
}

test('own-text editors commit their text without growing the enclosing shape or emitting a move', () => {
  const current = fixture({own: true, initialScrollHeight: 150})
  current.resetInvalidation()
  const version = current.canvas.layoutVersion, frames = current.frames()
  current.input('Own\nText\nLonger', 240)
  assertBaseline(current)
  assert.equal(current.node.measured, false)
  assert.equal(current.canvas.layoutVersion, version)
  assert.equal(current.frames(), frames)
  assert.deepEqual([...current.canvas.dirty], [])
  current.editor.dispatch('keydown', {key: 'Enter', metaKey: true})
  assertBaseline(current)
  assert.deepEqual(current.commands, [{name: 'hakushi:edit', payload: {node: 'shape', action: 'text', value: 'Own\nText\nLonger'}}])
})

test('native text mutation rereads preserve live preview geometry and rotated control origins through finish', () => {
  for (const finish of ['Escape', 'Meta+Enter', 'blur']) {
    const current = fixture()
    const {canvas, shape, editor} = current
    const northWest = () => shape.querySelector('[data-corner="nw"]').style.getPropertyValue('transform-origin')
    const rotator = () => shape.querySelector('.hakushi-rotator').style.getPropertyValue('transform-origin')
    const reread = () => {
      const previous = canvas.nodes.get('shape')
      // Native editText hides this element; the real MutationObserver sends its
      // style mutation through nodesChanged, which reconstructs the node.
      canvas.nodesChanged([{type: 'attributes', target: current.text, attributeName: 'style'}])
      const live = canvas.nodes.get('shape')
      assert.notEqual(live, previous)
      assert.equal(live.height, 175)
      assert.equal(live.handles[0].y, 175)
      assert.equal(shape.style.height, '175px')
      assert.equal(northWest(), '105px 92.5px')
      assert.equal(rotator(), '6px 115.5px')
    }
    current.input('Changed\nMultiline\nText', 174.2)
    reread()
    current.input('Changed\nMultiline\nText\nAgain', 174.2)
    reread()
    assert.deepEqual(current.commands, [])
    if (finish === 'blur') editor.dispatch('blur')
    else editor.dispatch('keydown', {key: finish === 'Escape' ? 'Escape' : 'Enter', metaKey: finish === 'Meta+Enter'})
    const live = canvas.nodes.get('shape')
    assert.equal(live.height, 80)
    assert.equal(current.node.height, 80)
    assert.equal(live.handles[0].y, 80)
    assert.equal(shape.style.height, '80.00px')
    assert.equal(northWest(), '105px 45px')
    assert.equal(rotator(), '6px 68px')
    assert.equal(current.rotated.style.getPropertyValue('--hakushi-rotation'), '-27deg')
    if (finish === 'Escape') assert.deepEqual(current.commands, [])
    else assert.deepEqual(current.commands, [
      {name: 'hakushi:edit', payload: {node: 'shape', action: 'text', value: 'Changed\nMultiline\nText\nAgain'}},
      {name: 'hakushi:change', payload: {op: 'move', nodes: [{id: 'shape', x: 40, y: 60, width: 200, height: 175}]}},
    ])
  }
})
