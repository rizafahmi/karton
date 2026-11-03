import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'
const source = await readFile(new URL('../assets/js/direct_keyboard.js', import.meta.url), 'utf8')
const {mountDirectKeyboard, adjacentThoughtBox} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

function element(tag) {
  const events = new Map(), attributes = new Map()
  const node = {
    tag, children: [], dataset: {}, style: {}, className: '', value: '', textContent: '',
    classList: {contains(name) { return node.className.split(' ').includes(name) }, remove(name) { node.className = node.className.split(' ').filter(value => value !== name).join(' ') }},
    setAttribute(name, value) { attributes.set(name, value) }, removeAttribute(name) { attributes.delete(name) },
    getAttribute(name) { return attributes.get(name) },
    addEventListener(name, fn) { events.set(name, fn) },
    append(...children) { node.children.push(...children); children.forEach(child => { child.parentElement = node }) },
    prepend(...children) { node.children.unshift(...children); children.forEach(child => { child.parentElement = node }) },
    remove() { if (node.parentElement) node.parentElement.children = node.parentElement.children.filter(child => child !== node) },
    focus() { document.activeElement = node },
    get scrollHeight() { return 16 + node.textContent.split('\n').reduce((sum, line) => sum + Math.max(1, Math.ceil(line.length / 14)), 0) * 20 },
    emit(name, extra = {}) {
      const event = {key: '', shiftKey: false, stopPropagation() {}, preventDefault() { this.defaultPrevented = true }, ...extra}
      events.get(name)?.(event)
      return event
    },
  }
  return node
}

function editor() {
  const handlers = new Map()
  const workspace = {directPreview: false, addEventListener(name, fn) { handlers.set(name, fn) }, removeEventListener() {}, querySelector() { return null }}
  const declarations = new Map()
  const style = {getPropertyValue(key) { return declarations.get(key) || '' }, setProperty(key, value) { declarations.set(key, value) }, removeProperty(key) { declarations.delete(key) }}
  const root = {closest: selector => selector === '#workspace' ? workspace : null, contains: target => target === root, addEventListener(name, fn) { handlers.set(`root:${name}`, fn) }, removeEventListener() {}, focus() { document.activeElement = root }, classList: {contains: () => false}}
  const labels = element('div')
  globalThis.document = {activeElement: root, createElement: element}
  globalThis.getComputedStyle = element => element.style
  globalThis.MutationObserver = class { observe() {} disconnect() {} }
  const calls = []
  const canvas = {root, labelsEl: labels, view: {x: 0, y: 0, zoom: 1}, size: {width: 1000, height: 800}, ui: {append() {}}, config: {}, nodes: new Map(), edges: new Map(), gone: new Set(), culled: new Set(), selected: new Set(), selectedEdges: new Set(), order: ['a', 'b', 'c'], focusIn() {}, drawOverlay() {}, pointerDown() {}, schedule() {}, decorate() {}, measureHandles() {}, touchNode() {}, announce() {}, revealNodes() {}, nodesChanged() {}, update() {}, undo() {}, redo() {}, setTool(value) { this.tool = value }, selectPending() {}, selectionChanged() {}, setSelection(value) { this.selected = value }, push(event, payload, callback) { calls.push({event, payload}); queueMicrotask(() => callback({})) }}
  for (const id of canvas.order) {
    const el = {dataset: {id}, isConnected: true, style, removeAttribute() {}, classList: {contains: value => value === 'hakushi-node'}, querySelector(selector) { return selector === '[data-hakushi-rotate]' ? {style} : selector === '[data-hakushi-text]' ? {dataset: {hakushiText: id}} : null }, closest(selector) { return selector === '.hakushi-node' ? this : null }, focus() { document.activeElement = this; canvas.focusIn({target: this}) }}
    canvas.nodes.set(id, {id, type: 'shape', label: id, x: 10, y: 20, width: 100, height: 80, el})
  }
  canvas.focusedNode = () => canvas.nodes.get(document.activeElement.dataset?.id) || canvas.nodes.get([...canvas.selected][0])
  const keyboard = mountDirectKeyboard(canvas)
  function key(value, extra = {}) {
    const event = {key: value, target: document.activeElement, shiftKey: false, preventDefault() { this.defaultPrevented = true }, ...extra}
    keyboard.key(event)
    if (value === ' ' && !extra.hold) handlers.get('root:keyup')?.(event)
    return event
  }
  return {
    canvas, workspace, calls, key, keyboard,
    draft: () => labels.children.find(child => child.className.includes('drawing-thought-preview')),
    input: () => labels.children.flatMap(child => child.children).find(child => child.tag === 'textarea'),
    flush() {
      const event = {detail: {waiters: []}, preventDefault() { this.defaultPrevented = true }}
      handlers.get('canvas:flush')(event)
      return event
    },
    leave: relatedTarget => handlers.get('root:focusout')({relatedTarget}),
    releaseSpace: () => handlers.get('root:keyup')?.({key: ' ', preventDefault() {}}),
  }
}

test('Tab and Space select a simple object or an arbitrary subset without navigation replacing it', () => {
  const {canvas, key} = editor()
  key('Tab'); key(' ')
  assert.deepEqual([...canvas.selected], ['a'])
  key('Tab'); key('Tab'); key(' ')
  assert.deepEqual([...canvas.selected], ['a', 'c'])
  key('Tab', {shiftKey: true}); key(' ')
  assert.deepEqual([...canvas.selected], ['a', 'c', 'b'])
  key('Tab', {shiftKey: true}); key(' ')
  assert.deepEqual([...canvas.selected], ['c', 'b'])
})

test('root Tab entry anchors the selected drawing in either direction, then traverses without selecting', () => {
  for (const shiftKey of [false, true]) {
    const {canvas, key} = editor()
    canvas.selected.add('b')
    assert.equal(key('Tab', {shiftKey}).defaultPrevented, true)
    assert.equal(document.activeElement, canvas.nodes.get('b').el)
    assert.equal(canvas.lastFocus, canvas.nodes.get('b').el)
    key('Tab', {shiftKey})
    assert.equal(document.activeElement, canvas.nodes.get(shiftKey ? 'a' : 'c').el)
    assert.deepEqual([...canvas.selected], ['b'])
  }
})

test('multi-selection entry uses the first live selected drawing in canvas order, not insertion order', () => {
  const {canvas, key} = editor()
  canvas.selected = new Set(['c', 'b', 'a'])
  canvas.gone.add('a')
  key('Tab')
  assert.equal(document.activeElement, canvas.nodes.get('b').el)
  key('Tab')
  assert.equal(document.activeElement, canvas.nodes.get('c').el)
  assert.deepEqual([...canvas.selected], ['c', 'b', 'a'])
})

test('selected-node anchoring preserves edge traversal, edge ambiguity and native exits', () => {
  const {canvas, key, draft} = editor()
  canvas.edges.set('edge', {id: 'edge', source: 'a', target: 'c'})
  canvas.selected.add('b')
  key('Tab'); key('Tab'); key('Tab')
  assert.equal(document.activeElement, canvas.root)
  key('n')
  assert.equal(draft(), undefined)
  key('Tab', {shiftKey: true})
  assert.equal(document.activeElement, canvas.nodes.get('c').el)
  key('Tab')
  assert.equal(key('Tab').defaultPrevented, undefined)
  assert.equal(document.activeElement, canvas.nodes.get('c').el)
  canvas.nodes.get('a').el.focus()
  assert.equal(key('Tab', {shiftKey: true}).defaultPrevented, undefined)
  assert.equal(document.activeElement, canvas.root)
  assert.deepEqual([...canvas.selected], ['b'])
})

test('empty canvas retains root focus and leaves both Tab directions native', () => {
  const {canvas, key} = editor()
  canvas.order = []
  canvas.nodes.clear()
  for (const shiftKey of [false, true]) {
    assert.equal(key('Tab', {shiftKey}).defaultPrevented, undefined)
    assert.equal(document.activeElement, canvas.root)
  }
})

test('geometry previews stay local and Escape restores authored dimensions without history', () => {
  const {canvas, calls, key, workspace} = editor()
  canvas.selected.add('a')
  key('g'); key('ArrowRight'); key('ArrowDown', {shiftKey: true})
  assert.equal(canvas.nodes.get('a').width, 101)
  assert.equal(canvas.nodes.get('a').height, 90)
  assert.equal(workspace.directPreview, true)
  assert.equal(calls.length, 0)
  key('Escape')
  assert.equal(canvas.nodes.get('a').width, 100)
  assert.equal(canvas.nodes.get('a').height, 80)
  assert.equal(workspace.directPreview, false)
  assert.equal(calls.length, 0)
})

test('file menu and copy focus retain geometry for one flush while unrelated departures cancel it', () => {
  for (const target of ['#file-menu-toggle', '#file-menu', '[data-save-copy]']) {
    const app = editor()
    app.canvas.selected.add('a')
    app.key('g'); app.key('ArrowRight')
    app.leave({closest: selector => selector.includes(target)})
    assert.equal(app.canvas.nodes.get('a').width, 101)
    assert.equal(app.workspace.directPreview, true)
    assert.deepEqual(app.calls, [])
    app.flush()
    assert.equal(app.workspace.directPreview, false)
    assert.deepEqual(app.calls, [{event: 'hakushi:change', payload: {op: 'move', nodes: [{id: 'a', x: 10, y: 20, width: 101, height: 80}]}}])
    app.flush()
    assert.equal(app.calls.length, 1)
  }
  const app = editor()
  app.canvas.selected.add('a')
  app.key('g'); app.key('ArrowRight')
  app.leave({closest: () => null})
  assert.equal(app.canvas.nodes.get('a').width, 100)
  assert.equal(app.workspace.directPreview, false)
  assert.deepEqual(app.calls, [])
})

test('Zen controls retain uncommitted geometry, thought text and staged connections', () => {
  for (const kind of ['geometry', 'thought', 'connection']) {
    const app = editor()
    app.canvas.selected.add('a')
    app.key(kind === 'geometry' ? 'g' : kind === 'thought' ? 'n' : 'c')
    let input
    if (kind !== 'connection') app.key('ArrowRight')
    if (kind === 'thought') {
      input = app.input()
      input.value = 'Keep this pending thought'
      input.emit('input')
    }
    app.leave({closest: selector => selector === '[data-zen-toggle]'})
    assert.equal(app.keyboard.active, true)
    assert.deepEqual(app.calls, [])
    assert.deepEqual([...app.canvas.selected], ['a'])
    if (kind === 'geometry') assert.equal(app.canvas.nodes.get('a').width, 101)
    if (kind === 'thought') {
      assert.equal(app.input(), input)
      assert.equal(input.value, 'Keep this pending thought')
      input.emit('keydown', {key: 'Escape'})
    } else app.key('Escape')
    assert.equal(app.keyboard.active, false)
    assert.deepEqual(app.calls, [])
    if (kind === 'geometry') assert.equal(app.canvas.nodes.get('a').width, 100)
    app.keyboard.destroy()
  }
})

test('a thought draft survives direct copy-control focus and still blocks an invalid flush', () => {
  const app = editor()
  app.key('Tab'); app.key('n'); app.key('ArrowRight')
  const input = app.input()
  input.value = 'x'.repeat(2001); input.emit('input')
  app.leave({closest: selector => selector.includes('[data-save-copy]')})
  assert.equal(app.input(), input)
  assert.equal(app.flush().defaultPrevented, true)
  assert.equal(app.input().value, 'x'.repeat(2001))
  assert.deepEqual(app.calls, [])
})


test('locked objects cannot enter geometry mode or emit edits', () => {
  const {canvas, calls, key} = editor()
  canvas.selected.add('a'); canvas.nodes.get('a').locked = true
  key('g'); key('ArrowRight'); key('Enter')
  assert.equal(canvas.nodes.get('a').width, 100)
  assert.equal(calls.length, 0)
})

test('rotated resizing keeps the opposite corner fixed, and rotation cancel restores the exact declaration', () => {
  const {canvas, key, calls} = editor()
  const node = canvas.nodes.get('a')
  node.el.style.setProperty('--hakushi-rotation', '90.00deg')
  canvas.selected.add('a')
  const opposite = () => ({x: node.x + node.width / 2 + node.height / 2, y: node.y + node.height / 2 - node.width / 2})
  const before = opposite()
  key('g'); key('ArrowDown', {shiftKey: true})
  assert.equal(node.width, 110)
  assert.equal(node.height, 80)
  assert.deepEqual(opposite(), before)
  key('Escape')
  assert.deepEqual([node.x, node.y, node.width, node.height], [10, 20, 100, 80])
  key('g'); key('Tab', {shiftKey: true}); key('ArrowRight')
  assert.equal(node.el.style.getPropertyValue('--hakushi-rotation'), '91deg')
  key('Escape')
  assert.equal(node.el.style.getPropertyValue('--hakushi-rotation'), '90.00deg')
  assert.equal(calls.length, 0)
})

test('holding Space through a pointer gesture never toggles the selected objects on release', () => {
  const {canvas, key, releaseSpace} = editor()
  key('Tab'); key(' ')
  key(' ', {hold: true})
  key(' ', {hold: true, repeat: true})
  canvas.pointerDown({})
  releaseSpace()
  assert.deepEqual([...canvas.selected], ['a'])
})

test('history commands cancel the preview before further keys can mutate a stale geometry baseline', () => {
  const {canvas, key, calls, workspace} = editor()
  canvas.selected.add('a')
  key('g'); key('ArrowRight')
  assert.equal(canvas.nodes.get('a').width, 101)
  key('z', {metaKey: true})
  assert.equal(canvas.nodes.get('a').width, 100)
  assert.equal(workspace.directPreview, false)
  key('ArrowRight'); key('Escape')
  assert.equal(canvas.nodes.get('a').width, 100)
  assert.equal(calls.length, 0)
})

test('browser Back leaves a changed preview unsaved, while the consumed stacking chord cancels it', () => {
  const {canvas, key, workspace} = editor()
  canvas.selected.add('a')
  key('g'); key('ArrowRight')
  key('[', {metaKey: true, code: 'BracketLeft'})
  assert.equal(canvas.nodes.get('a').width, 101)
  assert.equal(workspace.directPreview, true)
  key('{', {metaKey: true, shiftKey: true, code: 'BracketLeft'})
  assert.equal(canvas.nodes.get('a').width, 100)
  assert.equal(workspace.directPreview, false)
})

test('adjacent placement follows all four canvas axes and skips rotated blockers without touching them', () => {
  const source = {x: 0, y: 0, width: 100, height: 80, rotation: 90}
  assert.deepEqual(adjacentThoughtBox(source, [source], 'ArrowRight'), {x: 138, y: -8, width: 160, height: 96})
  assert.deepEqual(adjacentThoughtBox(source, [source], 'ArrowLeft'), {x: -198, y: -8, width: 160, height: 96})
  assert.deepEqual(adjacentThoughtBox(source, [source], 'ArrowUp'), {x: -30, y: -154, width: 160, height: 96})
  assert.deepEqual(adjacentThoughtBox(source, [source], 'ArrowDown'), {x: -30, y: 138, width: 160, height: 96})
  const blocker = {x: 180, y: 0, width: 100, height: 80, rotation: 90}
  const before = structuredClone([source, blocker])
  assert.equal(adjacentThoughtBox(source, [source, blocker], 'ArrowRight').x, 318)
  assert.deepEqual([source, blocker], before)
})

test('growing multiline geometry rechecks newly intersected blockers and preserves the cardinal ray', () => {
  const source = {x: -80, y: -40, width: 160, height: 80}
  const blocker = {x: 128, y: 120, width: 100, height: 80}
  assert.equal(adjacentThoughtBox(source, [source, blocker], 'ArrowRight').x, 128)
  const grown = adjacentThoughtBox(source, [source, blocker], 'ArrowRight', 300)
  assert.deepEqual(grown, {x: 276, y: -150, width: 160, height: 300})
})

test('direction and authored-text cancellation leave the graph and selection untouched without a mutation', () => {
  const app = editor()
  app.key('Tab'); app.key(' ')
  const before = [...app.canvas.nodes.values()].map(({el, ...node}) => structuredClone(node))
  app.key('n')
  assert.equal(app.keyboard.active, true)
  app.key('Escape')
  assert.equal(app.draft(), undefined)
  app.key('n'); app.key('ArrowRight')
  app.input().value = 'Do not create me'
  app.input().emit('input')
  app.input().emit('keydown', {key: 'Escape'})
  assert.equal(app.draft(), undefined)
  assert.equal(app.workspace.directPreview, false)
  assert.deepEqual([...app.canvas.selected], ['a'])
  assert.deepEqual([...app.canvas.nodes.values()].map(({el, ...node}) => node), before)
  assert.equal(app.calls.length, 0)
  assert.equal(document.activeElement, app.canvas.nodes.get('a').el)
})

test('root N uses one selected text shape without an extra Tab and cancellation preserves selection/history', () => {
  const app = editor()
  app.canvas.selected.add('b')
  app.key('n'); app.key('ArrowRight')
  assert.ok(app.input())
  assert.equal(app.draft().style.translate, '158px 12px')
  app.input().emit('keydown', {key: 'Escape'})
  assert.equal(app.draft(), undefined)
  assert.equal(document.activeElement, app.canvas.nodes.get('b').el)
  assert.deepEqual([...app.canvas.selected], ['b'])
  assert.equal(app.calls.length, 0)
})

test('focused shape takes precedence over a different or ambiguous selection for N', () => {
  const app = editor()
  app.canvas.selected = new Set(['a', 'b'])
  app.canvas.selectedEdges.add('edge')
  app.canvas.nodes.get('c').x = 500
  app.canvas.nodes.get('c').el.focus()
  app.key('n'); app.key('ArrowRight')
  assert.ok(app.input())
  assert.equal(app.draft().style.translate, '648px 12px')
  assert.deepEqual([...app.canvas.selected], ['a', 'b'])
  assert.deepEqual([...app.canvas.selectedEdges], ['edge'])
})

test('root N refuses ambiguous selection and ineligible selected drawings', () => {
  for (const configure of [
    () => {},
    app => { app.canvas.selected = new Set(['a', 'b']) },
    app => { app.canvas.selected.add('a'); app.canvas.selectedEdges.add('edge') },
    app => { app.canvas.selected.add('a'); app.canvas.nodes.get('a').locked = true },
    app => { app.canvas.selected.add('a'); app.canvas.gone.add('a') },
    app => { app.canvas.selected.add('a'); app.canvas.nodes.delete('a') },
    app => { app.canvas.selected.add('a'); app.canvas.config.readonly = true },
    app => { app.canvas.selected.add('a'); app.canvas.nodes.get('a').type = 'shape-line' },
    app => { app.canvas.selected.add('a'); app.canvas.tool = 'rect' },
    app => { app.canvas.selected.add('a'); app.canvas.gesture = {kind: 'move'} },
  ]) {
    const app = editor()
    configure(app)
    app.key('n')
    assert.equal(app.draft(), undefined)
    assert.equal(app.calls.length, 0)
  }
})

test('stale source geometry, selection, tools and history cancel drafts before they can add a thought', () => {
  for (const interrupt of [
    app => { app.canvas.nodes.get('a').x++; app.canvas.nodesChanged([]) },
    app => { app.canvas.nodes.delete('a'); app.canvas.nodesChanged([]) },
    app => { app.canvas.selected.add('b'); app.canvas.selectionChanged() },
    app => app.canvas.setTool('drawing:rect'),
    app => app.canvas.undo(),
    app => app.leave(null),
  ]) {
    const app = editor()
    app.key('Tab'); app.key('n'); app.key('ArrowDown')
    app.input().value = 'Draft'
    interrupt(app)
    assert.equal(app.draft(), undefined)
    assert.equal(app.workspace.directPreview, false)
    assert.equal(app.calls.length, 0)
  }
})

test('composing Enter stays native; an overlong grapheme draft remains intact and blocks Save without mutations', () => {
  const app = editor()
  app.key('Tab'); app.key('n'); app.key('ArrowDown')
  const input = app.input(), value = '👩🏽‍💻'.repeat(2001)
  input.value = value
  input.emit('input')
  input.emit('keydown', {key: 'Enter', isComposing: true})
  input.emit('keydown', {key: 'Enter', keyCode: 229})
  assert.equal(input.getAttribute('aria-invalid'), undefined)
  assert.equal(app.calls.length, 0)
  input.emit('keydown', {key: 'Enter'})
  assert.equal(input.value, value)
  assert.equal(input.getAttribute('aria-invalid'), 'true')
  assert.equal(app.flush().defaultPrevented, true)
  assert.equal(app.calls.length, 0)
  assert.equal(app.workspace.directPreview, true)
})

test('Save cancels an unplaced direction chooser without graph or dirty state changes', async () => {
  const chooser = editor()
  chooser.key('Tab'); chooser.key('n')
  await Promise.all(chooser.flush().detail.waiters)
  assert.equal(chooser.draft(), undefined)
  assert.equal(chooser.workspace.directPreview, false)
  assert.equal(chooser.calls.length, 0)
})

test('OS or tab focus loss keeps the in-memory thought; an explicit canvas departure still cancels', () => {
  const app = editor()
  app.key('Tab'); app.key('n'); app.key('ArrowRight')
  const input = app.input()
  input.value = 'Notes copied from another window'
  document.hasFocus = () => false
  app.leave(null)
  assert.equal(app.input(), input)
  assert.equal(input.value, 'Notes copied from another window')
  assert.equal(app.workspace.directPreview, true)
  assert.equal(app.calls.length, 0)
  document.hasFocus = () => true
  app.leave(null)
  assert.equal(app.draft(), undefined)
  assert.equal(app.workspace.directPreview, false)
  assert.equal(app.calls.length, 0)
})

test('direction re-entry and keys during an outstanding commit retain one editor and the entire original draft', () => {
  const app = editor()
  app.key('Tab'); app.key('n'); app.key('ArrowRight')
  const input = app.input()
  input.value = 'Keep this entire pending thought\nwith its authored second line'
  input.emit('input')
  app.canvas.root.focus(); app.key('ArrowUp')
  assert.equal(app.input(), input)
  assert.equal(document.activeElement, input)
  let acknowledge
  app.canvas.push = (_event, _payload, callback) => { acknowledge = callback }
  input.emit('keydown', {key: 'Enter'})
  assert.equal(input.readOnly, true)
  const originalText = input.value
  app.canvas.root.focus()
  app.key('Tab'); app.key('n'); app.key('ArrowUp'); app.key('Enter')
  assert.equal(app.draft().children.filter(child => child.tag === 'textarea').length, 1)
  assert.equal(app.input(), input)
  assert.equal(input.value, originalText)
  assert.equal(app.workspace.directPreview, true)
  acknowledge({ok: false, error: 'Draw refused'})
  assert.equal(app.input(), input)
  assert.equal(input.value, originalText)
  assert.equal(input.readOnly, false)
  assert.equal(document.activeElement, input)
  input.emit('keydown', {key: 'Escape'})
  assert.equal(app.draft(), undefined)
})

test('draft reveal clears persistent chrome and fits one text line with screen-sized hints, not authored height', () => {
  for (const size of [{width: 390, height: 740}, {width: 640, height: 360}]) {
    const app = editor()
    app.canvas.size = size
    app.canvas.view.zoom = 4
    app.canvas.root.getBoundingClientRect = () => ({left: 0, top: 0})
    app.canvas.controlsEl = {getBoundingClientRect: () => ({right: 70})}
    app.canvas.toolsEl = {getBoundingClientRect: () => ({top: size.height - 64})}
    app.workspace.querySelector = selector => selector === '.canvas-header'
      ? {getBoundingClientRect: () => ({bottom: 90})} : null
    app.key('Tab'); app.key('n'); app.key('ArrowRight')
    app.input().value = 'Long thought\n'.repeat(80)
    app.input().emit('input')
    const preview = app.draft(), view = app.canvas.view
    const [x, y] = preview.style.translate.split(' ').map(parseFloat)
    const bottom = size.height - 88
    assert.equal(view.zoom, Math.min(4, (size.width - 24 - 82) / 160, (bottom - 102 - 48 - 12) / 40))
    assert.ok(x * view.zoom + view.x >= 82)
    assert.ok(y * view.zoom + view.y >= 102)
    assert.ok(parseFloat(app.input().style.height) >= 40)
    assert.ok(parseFloat(app.input().style.height) < parseFloat(preview.style.height))
    const editorBottom = y * view.zoom + view.y + parseFloat(app.input().style.height) * view.zoom
    assert.ok(editorBottom + 48 + 8 <= bottom)
    const hint = preview.children.find(child => child.className === 'drawing-thought-hint')
    assert.ok(Math.abs(parseFloat(hint.style.fontSize) * view.zoom - 11) < 0.001)
    assert.equal(app.canvas.nodes.get('a').height, 80)
    assert.equal(app.calls.length, 0)
  }
})
