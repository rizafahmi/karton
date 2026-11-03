import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'

const source = await readFile(new URL('../assets/js/zen_mode.js', import.meta.url), 'utf8')
const {mountZenMode} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

function element(tag = 'div', attributes = {}) {
  const listeners = new Map()
  const node = {
    tag, attributes: {...attributes}, dataset: {}, children: [], parentElement: null, isConnected: true,
    append(...children) { for (const child of children) { child.parentElement = node; node.children.push(child) } },
    setAttribute(name, value) { node.attributes[name] = String(value) },
    getAttribute(name) { return node.attributes[name] },
    matches(selector) {
      return selector.split(',').some(part => {
        let value = part.trim()
        if (value.includes(':popover-open')) {
          if (!node.popoverOpen) return false
          value = value.replace(':popover-open', '')
        }
        const not = value.match(/:not\(([^)]+)\)/)
        if (not) { if (node.matches(not[1])) return false; value = value.replace(not[0], '') }
        const attrs = [...value.matchAll(/\[([^=\]]+)(?:="?([^"\]]*)"?)?\]/g)]
        if (attrs.some(([, name, expected]) => !(name in node.attributes) || expected !== undefined && node.attributes[name] !== expected)) return false
        value = value.replace(/\[[^\]]+\]/g, '')
        const id = value.match(/#([\w-]+)/)?.[1]
        if (id && node.attributes.id !== id) return false
        const classes = [...value.matchAll(/\.([\w-]+)/g)].map(match => match[1])
        if (classes.some(name => !(node.attributes.class || '').split(' ').includes(name))) return false
        const type = value.match(/^[\w-]+/)?.[0]
        return !type || node.tag === type
      })
    },
    closest(selector) { for (let current = node; current; current = current.parentElement) if (current.matches(selector)) return current; return null },
    contains(target) { return target === node || node.children.some(child => child.contains(target)) },
    querySelectorAll(selector) { return node.children.flatMap(child => [...(child.matches(selector) ? [child] : []), ...child.querySelectorAll(selector)]) },
    querySelector(selector) { return node.querySelectorAll(selector)[0] || null },
    addEventListener(name, callback) { if (!listeners.has(name)) listeners.set(name, new Set()); listeners.get(name).add(callback) },
    removeEventListener(name, callback) { listeners.get(name)?.delete(callback) },
    emit(name, extra = {}) {
      const event = {target: node, button: 0, key: '', shiftKey: false, defaultPrevented: false, preventDefault() { this.defaultPrevented = true }, stopImmediatePropagation() { this.stopped = true }, ...extra}
      for (const callback of listeners.get(name) || []) { callback(event); if (event.stopped) break }
      return event
    },
    focus() {
      document.activeElement = node
      const event = node.emit('focusin')
      if (!event.stopped && node.parentElement) node.parentElement.emit('focusin', {target: node})
      node.focuses = (node.focuses || 0) + 1
    },
  }
  return node
}

function fixture() {
  const body = element('body'), root = element('main'), nativeRoot = element(), nativeNode = element('div', {class: 'hakushi-node'}), endpoint = element('button', {class: 'drawing-line-endpoint'})
  const identity = element('div', {class: 'document-identity'}), menu = element('div', {id: 'file-menu'}), toggle = element('button', {'data-zen-toggle': ''}), exit = element('button', {'data-zen-toggle': '', class: 'zen-exit-control'})
  body.append(root); root.append(identity, nativeRoot, exit); identity.append(menu); menu.append(toggle); nativeRoot.append(nativeNode, endpoint)
  root.dataset.fileMode = 'untitled'
  const window = element()
  globalThis.window = window
  globalThis.document = {body, activeElement: nativeRoot, querySelector: selector => body.querySelector(selector)}
  const calls = [], keyboard = {active: false}
  const canvas = {root: nativeRoot, lastFocus: nativeNode, selected: new Set(['another']), selectedEdges: new Set(['edge']), view: {x: 23, y: 54, zoom: 1.5}, tool: null, gesture: null,
    togglePaperMenu(value) { calls.push(['paper', value]); this.paperMenu = null },
    toggleLayoutMenu(value) { calls.push(['layout', value]); this.layoutMenu = null },
  }
  // Like native focusIn: focusing a node normally selects it and moves the view.
  nativeRoot.addEventListener('focusin', event => { if (event.target === nativeNode) { canvas.selected = new Set(['node']); canvas.view.x = 999; keyboard.cursor = null } })
  const hook = {fileCanvas: canvas, fileCanvasReady: true, directKeyboard: keyboard}
  let currentHook = hook
  const workspace = {el: root, activeCanvas: () => currentHook, pushEvent: (...args) => calls.push(args)}
  const mode = mountZenMode(workspace)
  return {body, root, nativeRoot, nativeNode, endpoint, identity, menu, toggle, exit, canvas, keyboard, hook, calls, mode,
    enter: () => root.emit('canvas:toggle-zen'),
    key: (key, extra = {}) => window.emit('keydown', {key, target: document.activeElement, ...extra}),
    replace: value => { currentHook = value },
  }
}

const isZen = fixture => fixture.root.dataset.zenMode === 'true'

test('session transitions close chrome without altering graph, view or direct modes', () => {
  const f = fixture()
  const selected = f.canvas.selected, edges = f.canvas.selectedEdges, view = {...f.canvas.view}
  f.keyboard.active = true
  f.keyboard.cursor = 'edge'
  f.canvas.tool = {kit: 'shape', tool: 'line'}
  f.canvas.gesture = {kind: 'line-endpoint'}
  f.enter()
  assert.equal(isZen(f), true)
  assert.deepEqual(f.calls, [['paper', false], ['layout', false], ['close-overlays', {}]])
  assert.equal(f.keyboard.active, true)
  assert.equal(f.keyboard.cursor, 'edge')
  assert.equal(f.canvas.selected, selected)
  assert.equal(f.canvas.selectedEdges, edges)
  assert.deepEqual(f.canvas.view, view)
  f.root.emit('canvas:exit-zen')
  assert.equal(isZen(f), false)
  assert.equal(f.canvas.tool.tool, 'line')
  assert.equal(f.canvas.gesture.kind, 'line-endpoint')
})

test('entry is disabled until a document canvas is ready; exit remains enabled', () => {
  const f = fixture()
  f.hook.fileCanvasReady = false
  f.mode.updated()
  assert.equal(f.toggle.disabled, true)
  f.enter(); assert.equal(isZen(f), false)
  f.hook.fileCanvasReady = true
  f.root.emit('canvas:settled')
  assert.equal(f.toggle.disabled, false)
  f.enter()
  f.hook.fileCanvasReady = false
  f.mode.updated()
  assert.equal(f.exit.disabled, false)
  f.root.emit('canvas:exit-zen')
  assert.equal(isZen(f), false)
  f.root.dataset.fileMode = 'none'
  f.hook.fileCanvasReady = true
  f.mode.updated(); f.enter()
  assert.equal(isZen(f), false)
})

test('patches reapply session state and replacement control states without overlay feedback', () => {
  const f = fixture()
  f.enter()
  const replacement = element('button', {'data-zen-toggle': ''})
  f.menu.append(replacement)
  f.root.dataset.zenMode = 'false'
  f.mode.updated(); f.mode.updated()
  assert.equal(isZen(f), true)
  assert.equal(replacement.getAttribute('aria-pressed'), 'true')
  assert.equal(f.calls.length, 3)
  f.replace({...f.hook, fileCanvasReady: false})
  f.mode.updated()
  assert.equal(isZen(f), true)
  f.root.dataset.fileMode = 'none'
  f.mode.updated()
  assert.equal(isZen(f), false)
  f.root.dataset.fileMode = 'untitled'
  f.mode.updated()
  assert.equal(isZen(f), false)
})

test('Shift Z is scoped to exact canvas node endpoint focus, not toolbar, fields or unrelated focus', () => {
  const f = fixture()
  for (const target of [f.nativeRoot, f.nativeNode, f.endpoint]) {
    document.activeElement = target
    assert.equal(f.key('Z', {shiftKey: true}).defaultPrevented, true)
    assert.equal(isZen(f), true)
    f.mode.reveal()
  }
  const field = element('textarea'), toolbar = element('button'), editable = element('div', {contenteditable: 'true'}), child = element('span')
  f.nativeRoot.append(field, toolbar, editable); f.nativeNode.append(child)
  for (const target of [field, toolbar, editable, child, f.toggle, f.body]) {
    document.activeElement = target
    assert.equal(f.key('Z', {shiftKey: true}).defaultPrevented, false)
    assert.equal(isZen(f), false)
  }
})

test('shortcut leaves composition, repeated keys and platform modifiers untouched', () => {
  const f = fixture()
  for (const extra of [{isComposing: true}, {keyCode: 229}, {repeat: true}, {metaKey: true}, {ctrlKey: true}, {altKey: true}, {defaultPrevented: true}]) {
    const event = f.key('Z', {shiftKey: true, ...extra})
    assert.equal(isZen(f), false)
    assert.equal(event.stopped, undefined)
  }
  f.key('z'); assert.equal(isZen(f), false)
})

test('Escape defers to editors, G C N modes, gestures, tools, crop and native overlays first', () => {
  const f = fixture()
  f.enter()
  for (const property of ['tool', 'gesture', 'cropping']) {
    f.canvas[property] = {}
    assert.equal(f.key('Escape').defaultPrevented, false)
    assert.equal(isZen(f), true)
    f.canvas[property] = null
  }
  f.keyboard.active = true
  assert.equal(f.key('Escape').defaultPrevented, false)
  f.keyboard.active = false
  for (const className of ['hakushi-text-editor', 'hakushi-edge-input', 'drawing-thought-input']) {
    const editor = element('textarea', {class: className})
    f.nativeRoot.append(editor)
    assert.equal(f.key('Escape').defaultPrevented, false)
    f.nativeRoot.children.pop()
  }
  const popover = element('div', {id: 'native-popover'}); popover.popoverOpen = true; f.root.append(popover)
  assert.equal(f.key('Escape').defaultPrevented, false)
  popover.popoverOpen = false
  f.canvas.paperMenu = element()
  assert.equal(f.key('Escape').defaultPrevented, false)
  f.canvas.paperMenu = null
  const dialog = element('dialog', {open: ''}); f.body.append(dialog)
  assert.equal(f.key('Escape').defaultPrevented, false)
  f.body.children.pop()
  const event = f.key('Escape')
  assert.equal(event.defaultPrevented, true)
  assert.equal(event.stopped, true)
  assert.equal(isZen(f), false)
})

test('Escape uses its actual target and does not exit for unrelated fields or dialogs', () => {
  const f = fixture(); f.enter()
  const field = element('input'), dialog = element('dialog'), inner = element('button')
  f.root.append(field, dialog); dialog.append(inner)
  for (const target of [field, inner, f.body]) assert.equal(f.key('Escape', {target}).defaultPrevented, false)
  assert.equal(isZen(f), true)
})

test('entry and patched hidden focus recover native lastFocus without selecting or panning', () => {
  const f = fixture()
  document.activeElement = f.toggle
  const selected = f.canvas.selected, view = {...f.canvas.view}
  f.keyboard.cursor = 'edge'
  f.enter()
  assert.equal(document.activeElement, f.nativeNode)
  assert.equal(f.canvas.lastFocus, f.nativeNode)
  assert.equal(f.canvas.selected, selected)
  assert.deepEqual(f.canvas.view, view)
  assert.equal(f.keyboard.cursor, 'edge')
  document.activeElement = f.toggle
  f.mode.updated()
  assert.equal(document.activeElement, f.nativeNode)
  f.canvas.lastFocus = f.toggle
  document.activeElement = f.toggle
  f.mode.updated()
  assert.equal(document.activeElement, f.nativeRoot)
})

test('toggle pointer preserves pending text drafts and direct preview focus without commits', () => {
  const f = fixture(), input = element('textarea', {class: 'hakushi-text-editor'})
  input.value = 'uncommitted text'
  f.nativeRoot.append(input)
  document.activeElement = input
  assert.equal(f.root.emit('pointerdown', {target: f.toggle}).defaultPrevented, true)
  f.enter()
  assert.equal(document.activeElement, input)
  assert.equal(input.value, 'uncommitted text')
  f.root.emit('canvas:exit-zen')
  assert.equal(document.activeElement, input)
  document.activeElement = f.nativeRoot
  f.keyboard.active = true
  assert.equal(f.root.emit('pointerdown', {target: f.toggle}).defaultPrevented, true)
  f.keyboard.active = false
  assert.equal(f.root.emit('pointerdown', {target: f.toggle}).defaultPrevented, false)
})

test('reveal is idempotent and does not compete with requested UI focus', () => {
  const f = fixture(); f.enter()
  document.activeElement = f.exit
  f.mode.reveal(); f.mode.reveal()
  assert.equal(isZen(f), false)
  assert.equal(document.activeElement, f.exit)
  assert.equal(f.canvas.root.focuses, undefined)
})

test('unrelated modal focus is never stolen and teardown removes every controller listener', () => {
  const f = fixture(); f.enter()
  const modal = element('dialog', {open: ''}), input = element('input')
  f.body.append(modal); modal.append(input); document.activeElement = input
  f.mode.updated()
  assert.equal(document.activeElement, input)
  f.mode.destroyed(); f.mode.destroyed()
  assert.equal(isZen(f), false)
  f.enter(); f.mode.updated()
  document.activeElement = f.nativeRoot
  assert.equal(f.key('Z', {shiftKey: true}).defaultPrevented, false)
  assert.equal(isZen(f), false)
  assert.equal(f.root.emit('pointerdown', {target: f.toggle}).defaultPrevented, false)
})

test('entry dismisses only open zoom and modal-owned entry stays unavailable', () => {
  const f = fixture(), zoom = element('div', {class: 'zoom-popover'})
  let dismissed = 0
  zoom.hidePopover = () => { dismissed++; zoom.popoverOpen = false }
  f.nativeRoot.append(zoom)
  f.enter()
  assert.equal(dismissed, 0)
  f.mode.reveal()
  zoom.popoverOpen = true
  f.enter()
  assert.equal(dismissed, 1)
  f.mode.reveal()
  const modal = element('dialog', {open: ''})
  f.body.append(modal)
  f.enter()
  assert.equal(isZen(f), false)
})

test('replacement ready canvas retains Zen but no prior document focus reference', () => {
  const f = fixture()
  f.enter()
  const nextRoot = element(), nextNode = element('div', {class: 'hakushi-node'})
  nextRoot.append(nextNode); f.root.append(nextRoot)
  const next = {...f.canvas, root: nextRoot, lastFocus: f.nativeNode}
  f.replace({fileCanvas: next, fileCanvasReady: true, directKeyboard: {active: false}})
  document.activeElement = f.toggle
  f.root.emit('canvas:settled')
  assert.equal(isZen(f), true)
  assert.equal(document.activeElement, nextRoot)
  assert.equal(next.lastFocus, nextRoot)
})

test('a fresh mount never inherits the previous mounted session preference', () => {
  const f = fixture(); f.enter(); f.mode.destroyed()
  f.root.dataset.zenMode = 'true'
  const next = mountZenMode({el: f.root, activeCanvas: () => f.hook, pushEvent() {}})
  assert.equal(isZen(f), false)
  next.destroyed()
})

test('Escape exits from Exit Zen and ordinary drawing tools but leaves message actions alone', () => {
  for (const control of ['exit', 'tool']) {
    const f = fixture(), tool = element('button')
    f.nativeRoot.append(tool)
    f.enter()
    const target = control === 'exit' ? f.exit : tool
    document.activeElement = target
    assert.equal(f.key('Escape').defaultPrevented, true)
    assert.equal(isZen(f), false)
    assert.notEqual(document.activeElement, f.exit)
  }
  const f = fixture(), messages = element('div', {id: 'canvas-messages', popover: 'manual'}), action = element('button')
  messages.append(action); f.root.append(messages)
  messages.popoverOpen = true
  f.enter()
  document.activeElement = action
  assert.equal(f.key('Escape').defaultPrevented, false)
  assert.equal(isZen(f), true)
})
