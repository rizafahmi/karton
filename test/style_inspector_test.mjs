import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'

const source = await readFile(new URL('../assets/js/style_inspector.js', import.meta.url), 'utf8')
const {mountStyleInspector} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
const nativeShapes = await readFile(new URL('../deps/hakushi/lib/hakushi/kits/shapes.ex', import.meta.url), 'utf8')
// Eligibility fixtures follow the installed native renderer's actual shape map.
const shapeKeys = kind => nativeShapes.match(new RegExp(`defp style_keys\\(${kind === 'other' ? '_kind' : '"' + kind + '"'}\\), do: ~w\\(([^)]+)\\)`))[1].split(' ')
const walk = node => [node, ...node.children.flatMap(walk)]
function element(tag) {
  const attributes = new Map(), listeners = new Map()
  const el = {
    tag, children: [], dataset: {}, className: '', textContent: '', value: '', hidden: false, disabled: false,
    style: {setProperty() {}},
    setAttribute(key, value) { attributes.set(key, String(value)) },
    getAttribute(key) { return attributes.get(key) ?? null },
    removeAttribute(key) { attributes.delete(key) },
    append(...children) { for (const child of children) { child.parentElement = el; el.children.push(child) } },
    replaceChildren(...children) { for (const child of el.children) child.parentElement = null; el.children = []; el.append(...children) },
    remove() { if (el.parentElement) el.parentElement.children = el.parentElement.children.filter(child => child !== el); el.parentElement = null },
    addEventListener(key, listener) { listeners.set(key, listener) },
    dispatchEvent(event) { return el.emit(event.type, event) },
    emit(type, extra = {}) { const event = {target: el, preventDefault() { this.defaultPrevented = true }, stopPropagation() { this.stopped = true }, ...extra}; listeners.get(type)?.(event); return event },
    focus() { document.activeElement = el },
  }
  return el
}
const definitions = [
  ['fill', 'color', ['none', 'ink', 'blue', 'accent', 'surface']],
  ['stroke', 'color', ['none', 'ink', 'blue', 'accent', 'surface']],
  ['width', 'width', [1, 2, 4]], ['dash', 'choice', [false, true]],
  ['radius', 'choice', [0, 8]], ['size', 'choice', ['s', 'm', 'l']],
  ['align', 'choice', ['left', 'center', 'right']], ['arrow', 'choice', ['end', 'both', 'none']],
  ['font', 'choice', ['sans', 'heading', 'mono', 'handwritten']],
].map(([key, kind, values]) => ({key, kind, label: key, options: values.map(value => ({value, label: String(value)}))}))
function fixture() {
  const observers = []
  globalThis.document = {activeElement: null, createElement: element}
  globalThis.MutationObserver = class { constructor(callback) { this.callback = callback; observers.push(this) } observe() {} disconnect() { this.disconnected = true } }
  globalThis.CustomEvent = class { constructor(type, options) { this.type = type; Object.assign(this, options) } }
  const workspace = {dataset: {drawingFont: 'mono'}}
  const root = {dataset: {}, closest: () => workspace}
  const calls = [], ui = element('div')
  const original = () => {}
  const canvas = {id: 'board', root, ui, config: {styles: [{types: ['shape', 'shape-line'], groups: definitions}]}, nodes: new Map(), edges: new Map(), selected: new Set(), selectedEdges: new Set(), gone: new Set(), drawStylePanel: original, push(event, payload, reply) { calls.push({event, payload, reply}) }}
  function node(id, kind, overrides = {}, font) {
    const defaults = {fill: 'none', stroke: 'ink', width: 2, dash: false, radius: 0, size: 'm', align: 'left', arrow: 'end'}
    const keys = kind === 'line' ? ['stroke', 'width', 'dash', 'arrow'] : shapeKeys(['rect', 'text'].includes(kind) ? kind : 'other')
    const style = {...Object.fromEntries(keys.map(key => [key, defaults[key]])), ...overrides}
    const shape = {dataset: {kind, hakushiStyle: JSON.stringify(style)}}
    const object = font ? {dataset: {drawingFont: font}} : null
    const node = {id, type: kind === 'line' ? 'shape-line' : 'shape', x: 12, y: 25, width: 160, height: 90, label: 'Unchanged', el: {querySelector: selector => selector === '[data-hakushi-style]' ? shape : object}}
    canvas.nodes.set(id, node)
    return {node, shape}
  }
  const controls = key => walk(canvas.styleEl).filter(el => el.dataset.key === key)
  const control = key => controls(key).find(el => el.tag === 'select' || el.className === 'style-color-trigger')
  const option = (key, value) => controls(key).find(el => el.dataset.value === JSON.stringify(value))
  const draw = () => canvas.drawStylePanel()
  const mount = () => mountStyleInspector(canvas)
  return {canvas, calls, workspace, node, controls, control, option, draw, mount, observers, original}
}

test('native shape eligibility is intersected across rect, other shape, text and lines', () => {
  for (const [kinds, expected] of [
    [['rect'], [...shapeKeys('rect'), 'font']],
    [['ellipse'], [...shapeKeys('other'), 'font']],
    [['text'], [...shapeKeys('text'), 'font']],
    [['line'], ['stroke', 'width', 'dash', 'arrow']],
    [['rect', 'text'], ['fill', 'size', 'align', 'font']],
    [['rect', 'line'], ['stroke', 'width', 'dash']],
  ]) {
    const f = fixture()
    kinds.forEach((kind, i) => { f.node(String(i), kind); f.canvas.selected.add(String(i)) })
    f.mount()
    const keys = new Set(walk(f.canvas.styleEl).map(el => el.dataset.key).filter(Boolean))
    assert.deepEqual([...keys].sort(), expected.sort())
    assert.equal(f.calls.length, 0)
  }
})

test('effective inherited and explicit fonts display without changing native DOM, geometry or selection', () => {
  const f = fixture(), a = f.node('a', 'rect'), b = f.node('b', 'text', {}, 'mono')
  f.canvas.selected = new Set(['a', 'b'])
  const before = JSON.stringify([a, b])
  f.mount()
  assert.equal(f.control('font').value, '"mono"')
  f.draw(); f.draw()
  assert.equal(JSON.stringify([a, b]), before)
  assert.deepEqual([...f.canvas.selected], ['a', 'b'])
  assert.equal(f.calls.length, 0)
  f.workspace.dataset.drawingFont = 'heading'; f.draw()
  assert.equal(f.control('font').value, '__mixed__')
})

test('sparse default width matches explicit width and each edit is one property for live nodes only', () => {
  const f = fixture()
  f.node('a', 'line', {width: undefined}); f.node('b', 'line')
  f.canvas.selected = new Set(['a', 'b']); f.canvas.selectedEdges.add('e'); f.canvas.edges.set('e', {id: 'e'})
  f.mount()
  assert.equal(f.control('width').value, '2')
  assert.match(walk(f.canvas.styleEl).find(el => el.className === 'style-inspector-message').textContent, /connections.*unchanged/)
  f.control('width').value = '4'; f.control('width').emit('change')
  assert.deepEqual(f.calls[0].payload, {nodes: ['a', 'b'], action: 'style', style: {width: 4}})
  assert.equal(f.calls[0].event, 'hakushi:edit')
  assert.equal(f.calls.length, 1)
})

test('connector controls retain legacy Default and inherited animated dash, never arrowheads', () => {
  const f = fixture()
  f.canvas.edges.set('e', {id: 'e', animated: true}); f.canvas.selectedEdges.add('e')
  f.canvas.root.dataset.connectorStyles = JSON.stringify({e: {stroke: 'unknown'}})
  f.mount()
  assert.equal(f.control('stroke').children[1].textContent, 'Default')
  assert.equal(f.option('stroke', 'ink').getAttribute('aria-pressed'), 'false')
  assert.equal(f.control('dash').value, 'true')
  assert.equal(f.controls('arrow').length, 0)
  f.option('stroke', 'accent').emit('click')
  assert.deepEqual(f.calls[0].payload, {edges: ['e'], key: 'stroke', value: 'accent'})
  assert.equal(f.calls[0].event, 'drawing:edge-style')
  f.canvas.edges.set('other', {id: 'other', animated: false}); f.canvas.selectedEdges.add('other'); f.draw()
  assert.equal(f.control('dash').value, '__mixed__')
})

test('same-selection redraw preserves actual native select, focus and disclosure; selection change invalidates handlers', () => {
  const f = fixture(); const a = f.node('a', 'rect'); f.node('b', 'text'); f.canvas.selected.add('a'); f.mount()
  const select = f.control('width'), trigger = f.control('fill')
  select.focus(); f.draw(); assert.equal(f.control('width'), select); assert.equal(document.activeElement, select)
  trigger.emit('click'); const palette = walk(f.canvas.styleEl).find(el => el.className === 'style-color-palette')
  f.option('fill', 'blue').focus()
  a.shape.dataset.hakushiStyle = JSON.stringify({...JSON.parse(a.shape.dataset.hakushiStyle), fill: 'blue'})
  f.draw(); assert.equal(palette.hidden, false); assert.equal(document.activeElement, f.option('fill', 'blue'))
  const escape = f.canvas.styleEl.emit('keydown', {key: 'Escape'})
  assert.equal(escape.defaultPrevented, true); assert.equal(escape.stopped, true); assert.equal(palette.hidden, true); assert.equal(document.activeElement, trigger)
  const stale = f.option('fill', 'blue')
  trigger.emit('click'); f.canvas.selected = new Set(['b']); f.draw()
  assert.equal(f.control('fill').getAttribute('aria-expanded'), 'false')
  stale.emit('click'); assert.equal(f.calls.length, 0)
})

test('empty, locked, readonly and active-tool inspector stays present, refuses mutation and cleans up', () => {
  for (const mode of ['empty', 'locked', 'readonly', 'tool', 'crop']) {
    const f = fixture()
    if (mode !== 'empty') { const {node} = f.node('a', 'rect'); f.canvas.selected.add('a'); node.locked = mode === 'locked' }
    if (mode === 'readonly') f.canvas.config.readonly = true
    if (mode === 'tool') f.canvas.tool = {tool: 'rect'}
    if (mode === 'crop') f.canvas.cropping = {}
    const cleanup = f.mount()
    assert.equal(f.canvas.ui.children.includes(f.canvas.styleEl), true)
    const message = walk(f.canvas.styleEl).find(el => el.className === 'style-inspector-message')
    assert.equal(message.hidden, false)
    if (mode !== 'empty') { assert.equal(f.option('fill', 'blue').disabled, true); f.option('fill', 'blue').emit('click') }
    assert.equal(f.calls.length, 0)
    cleanup(); assert.equal(f.canvas.drawStylePanel, f.original); assert.equal(f.canvas.styleEl, null); assert.equal(f.observers[0].disconnected, true)
  }
})

test('server refusal is visible without optimistic mutation or extra command', () => {
  const f = fixture(), a = f.node('a', 'rect'); f.canvas.selected.add('a'); f.mount()
  const before = a.shape.dataset.hakushiStyle
  f.option('fill', 'blue').emit('click')
  f.calls[0].reply({error: 'Style change refused'})
  const error = walk(f.canvas.styleEl).find(el => el.className === 'style-inspector-error')
  assert.equal(error.hidden, false); assert.equal(error.getAttribute('role'), 'alert')
  assert.equal(a.shape.dataset.hakushiStyle, before); assert.equal(f.calls.length, 1)
})

test('closing the host panel collapses disclosure and Close emits the native integration event', () => {
  const f = fixture(); f.node('a', 'rect'); f.canvas.selected.add('a'); f.mount()
  assert.equal(f.canvas.styleEl.id, 'board-style-inspector')
  const trigger = f.control('fill')
  trigger.emit('click')
  f.workspace.dataset.styleOpen = 'false'
  f.observers[0].callback([{attributeName: 'data-style-open'}])
  assert.equal(trigger.getAttribute('aria-expanded'), 'false')
  let closeEvent
  f.canvas.styleEl.addEventListener('canvas:close-style', event => { closeEvent = event })
  walk(f.canvas.styleEl).find(el => el.className === 'style-inspector-close').emit('click')
  assert.equal(closeEvent.bubbles, true)
  assert.equal(f.calls.length, 0)
})

test('inspector title identifies its editing scope and mixed segmented sizes are explicit', () => {
  const f = fixture()
  const a = f.node('a', 'rect'), b = f.node('b', 'text', {size: 'l'})
  f.node('line', 'line'); f.canvas.edges.set('edge', {id: 'edge'})
  const title = () => walk(f.canvas.styleEl).find(el => el.className === 'style-inspector-title').textContent
  f.canvas.selected.add('a'); f.mount()
  const rectangleTitle = title()
  assert.deepEqual([...new Set(walk(f.canvas.styleEl).map(el => el.dataset.key).filter(Boolean))], ['fill', 'stroke', 'width', 'dash', 'radius', 'font', 'size', 'align'])
  f.canvas.selected = new Set(['b']); f.draw()
  const textTitle = title()
  f.canvas.selected = new Set(['line']); f.draw()
  const lineTitle = title()
  f.canvas.selected.clear(); f.canvas.selectedEdges.add('edge'); f.draw()
  const connectionTitle = title()
  assert.equal(new Set([rectangleTitle, textTitle, lineTitle, connectionTitle]).size, 4)
  f.canvas.selected = new Set(['a', 'b']); f.draw()
  assert.match(title(), /2/)
  const mixedLabel = walk(f.canvas.styleEl).find(el => el.className === 'style-inspector-message' && el.textContent === 'Mixed')
  assert.equal(mixedLabel.hidden, false)
  b.shape.dataset.hakushiStyle = a.shape.dataset.hakushiStyle
  f.draw(); assert.equal(mixedLabel.hidden, true)
  assert.equal(f.calls.length, 0)
})

test('mixed code and shapes share only meaningful properties, without source or font edits', () => {
  for (const kind of ['rect', 'text', 'line']) {
    const f = fixture()
    f.node('shape', kind)
    const code = f.node('code', 'rect').node
    code.type = 'code'
    code.el.querySelector = selector => selector === '[data-code-node]' ? {dataset: {codeSize: 'm'}} : selector === '[data-hakushi-style]' ? {dataset: {hakushiStyle: '{"fill":"none","stroke":"ink","width":2,"dash":false,"radius":0}'}} : null
    f.canvas.config.styles.push({types: ['code'], groups: definitions.filter(group => ['fill', 'stroke', 'width', 'dash', 'radius', 'size'].includes(group.key))})
    f.canvas.selected = new Set(['shape', 'code']); f.mount()
    const keys = new Set(walk(f.canvas.styleEl).map(el => el.dataset.key).filter(Boolean))
    const expected = kind === 'text' ? ['fill', 'size'] : kind === 'line' ? ['stroke', 'width', 'dash'] : ['fill', 'stroke', 'width', 'dash', 'radius', 'size']
    assert.deepEqual([...keys].sort(), expected.sort())
    assert.equal(f.calls.length, 0)
    f.workspace.codeDraft = true; f.draw()
    assert.ok(walk(f.canvas.styleEl).filter(el => el.dataset.key).every(el => el.disabled || el.tag === 'span'))
  }
})
