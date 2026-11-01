import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'
const source = await readFile(new URL('../assets/js/direct_keyboard.js', import.meta.url), 'utf8')
const {mountDirectKeyboard} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

function editor() {
  const handlers = new Map()
  const workspace = {directPreview: false, addEventListener(name, fn) { handlers.set(name, fn) }, removeEventListener() {}, querySelector() { return null }}
  const declarations = new Map()
  const style = {getPropertyValue(key) { return declarations.get(key) || '' }, setProperty(key, value) { declarations.set(key, value) }, removeProperty(key) { declarations.delete(key) }}
  const root = {closest: selector => selector === '#workspace' ? workspace : null, contains: target => target === root, addEventListener(name, fn) { handlers.set(`root:${name}`, fn) }, removeEventListener() {}, focus() { document.activeElement = root }, classList: {contains: () => false}}
  globalThis.document = {activeElement: root, createElement() { return {setAttribute() {}, style: {}, remove() {}} }}
  globalThis.getComputedStyle = element => element.style
  globalThis.MutationObserver = class { observe() {} disconnect() {} }
  const calls = []
  const canvas = {root, ui: {append() {}}, config: {}, nodes: new Map(), edges: new Map(), gone: new Set(), culled: new Set(), selected: new Set(), selectedEdges: new Set(), order: ['a', 'b', 'c'], focusIn() {}, drawOverlay() {}, pointerDown() {}, schedule() {}, decorate() {}, touchNode() {}, announce() {}, revealNodes() {}, selectionChanged() {}, setSelection(value) { this.selected = value }, push(event, payload, callback) { calls.push({event, payload}); callback({}) }}
  for (const id of canvas.order) {
    const el = {dataset: {id}, isConnected: true, style, removeAttribute() {}, classList: {contains: value => value === 'hakushi-node'}, querySelector(selector) { return selector === '[data-hakushi-rotate]' ? {style} : null }, closest(selector) { return selector === '.hakushi-node' ? this : null }, focus() { document.activeElement = this; canvas.focusIn({target: this}) }}
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
  return {canvas, workspace, calls, key, releaseSpace: () => handlers.get('root:keyup')?.({key: ' ', preventDefault() {}})}
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
