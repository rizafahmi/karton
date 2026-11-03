import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'

const source = await readFile(new URL('../assets/js/text_attachments.js', import.meta.url), 'utf8')
const {mountTextAttachments} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
const utf8 = new TextEncoder()
const deferred = () => {
  let resolve, reject
  const promise = new Promise((done, fail) => { resolve = done; reject = fail })
  return {promise, resolve, reject}
}
const settle = async () => { for (let index = 0; index < 8; index++) await Promise.resolve() }

function element(tag = 'div') {
  const listeners = new Map(), attributes = new Map()
  const el = {
    tagName: tag.toUpperCase(), id: '', className: '', dataset: {}, children: [], parentElement: null,
    ownText: '', isConnected: true, hidden: false, open: false, disabled: false, value: '', files: [],
    get textContent() { return this.ownText + this.children.map(child => child.textContent).join('') },
    set textContent(value) { this.ownText = String(value); for (const child of this.children) child.parentElement = null; this.children = [] },
    classList: {contains: name => el.className.split(/\s+/).includes(name)},
    getAttribute(name) { return attributes.get(name) ?? null },
    setAttribute(name, value) { attributes.set(name, String(value)) },
    removeAttribute(name) { attributes.delete(name) },
    append(...children) {
      for (const child of children) {
        if (child.parentElement) child.parentElement.children = child.parentElement.children.filter(current => current !== child)
        child.parentElement = this; child.isConnected = this.isConnected; this.children.push(child)
      }
    },
    remove() {
      if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this)
      this.parentElement = null; this.isConnected = false
    },
    contains(target) { return target === this || this.children.some(child => child.contains(target)) },
    matches(selector) {
      if (selector.startsWith('#')) return this.id === selector.slice(1)
      if (selector === '.hakushi-node[data-id]') return this.classList.contains('hakushi-node') && !!this.dataset.id
      if (selector === '.drawing-typography[data-attachment]') return this.classList.contains('drawing-typography') && this.dataset.attachment !== undefined
      if (selector.startsWith('.')) return this.classList.contains(selector.slice(1))
      if (selector === '[contenteditable]:not([contenteditable=false])') return this.contentEditable === 'true'
      if (selector === 'a[href]') return this.tagName === 'A' && !!this.href
      if (selector.startsWith('[')) return false
      return this.tagName.toLowerCase() === selector
    },
    closest(selectors) {
      for (let current = this; current; current = current.parentElement) {
        if (selectors.split(',').some(selector => current.matches(selector.trim()))) return current
      }
      return null
    },
    querySelector(selectors) {
      for (const child of this.children) {
        if (selectors.split(',').some(selector => child.matches(selector.trim()))) return child
        const found = child.querySelector(selectors)
        if (found) return found
      }
      return null
    },
    addEventListener(name, callback, capture = false) {
      const key = `${name}:${capture === true || capture?.capture === true}`
      const callbacks = listeners.get(key) || new Set()
      callbacks.add(callback); listeners.set(key, callbacks)
    },
    removeEventListener(name, callback, capture = false) {
      listeners.get(`${name}:${capture === true || capture?.capture === true}`)?.delete(callback)
    },
    dispatchEvent(event) {
      event.target ||= this
      for (const capture of [true, false]) {
        for (const callback of listeners.get(`${event.type}:${capture}`) || []) {
          callback(event)
          if (event.stopped) return !event.defaultPrevented
        }
      }
      return !event.defaultPrevented
    },
    async emit(type, extra = {}) {
      const event = {type, target: this, defaultPrevented: false, preventDefault() { this.defaultPrevented = true },
        stopImmediatePropagation() { this.stopped = true }, ...extra}
      for (const capture of [true, false]) {
        for (const callback of listeners.get(`${type}:${capture}`) || []) {
          await callback(event)
          if (event.stopped) return event
        }
      }
      return event
    },
    listenerCount() { return [...listeners.values()].reduce((count, callbacks) => count + callbacks.size, 0) },
    click() { return this.onClick?.() },
    focus() { document.activeElement = this },
    getBoundingClientRect() { return this.bounds || {left: 0, top: 0, right: 1000, bottom: 800, width: 1000, height: 800} },
    showModal() {
      this.invoker = document.activeElement; this.open = true
      const autofocus = this.find(child => child.autofocus)
      autofocus?.focus()
    },
    close() {
      this.open = false
      if (this.invoker?.isConnected) this.invoker.focus()
      this.dispatchEvent({type: 'close'})
    },
    find(predicate) {
      for (const child of this.children) { if (predicate(child)) return child; const found = child.find(predicate); if (found) return found }
      return null
    },
  }
  return el
}

function fixture({reply, flush, dataset = {}, downloadError} = {}) {
  const body = element('body'), root = element('section'), input = element('input'), trigger = element('button')
  root.id = 'workspace'
  root.dataset = {generation: '1', fileMode: 'untitled', nativeBusy: 'false', fileBusy: 'false',
    attachmentFileLimit: '262144', attachmentTotalLimit: '1048576', ...dataset}
  input.id = 'attachment-file-input'; trigger.id = 'attach-text-file'; trigger.textContent = 'Attach text file'
  let clicks = 0
  input.onClick = () => { clicks++ }
  const canvasRoot = element(), canvasElement = element()
  canvasRoot.id = 'canvas'; canvasElement.id = 'canvas-nodes'
  canvasElement.fileCanvasReady = true
  const header = element('header'), controls = element(), dock = element()
  header.className = 'canvas-header'; controls.className = 'hakushi-controls'; dock.className = 'hakushi-tools'
  header.bounds = {left: 0, top: 0, right: 1000, bottom: 84}
  controls.bounds = {left: 16, top: 108, right: 64, bottom: 400}
  dock.bounds = {left: 200, top: 700, right: 800, bottom: 780}
  canvasRoot.append(canvasElement, controls, dock); root.append(header, trigger, input, canvasRoot); body.append(root)
  const calls = [], selected = [], revealed = [], announced = [], downloads = [], blobs = [], revoked = [], observers = []
  globalThis.document = {body, activeElement: trigger, elementFromPoint: () => null, createElement: tag => {
    const el = element(tag)
    if (tag === 'a') el.onClick = () => { if (downloadError) throw downloadError; downloads.push({href: el.href, filename: el.download}) }
    return el
  }}
  globalThis.CustomEvent = class {
    constructor(type, options = {}) { this.type = type; this.detail = options.detail; this.defaultPrevented = false }
    preventDefault() { this.defaultPrevented = true }
  }
  globalThis.MutationObserver = class {
    constructor(callback) { this.callback = callback; observers.push(this) }
    observe() {}
    disconnect() { this.disconnected = true }
  }
  const originalCreate = URL.createObjectURL, originalRevoke = URL.revokeObjectURL
  URL.createObjectURL = blob => { blobs.push(blob); return `blob:attachment-${blobs.length}` }
  URL.revokeObjectURL = url => { revoked.push(url) }
  const canvas = {root: canvasRoot, nodesEl: canvasElement, controlsEl: controls, toolsEl: dock,
    config: {}, view: {x: 20, y: -30, zoom: 2}, size: {width: 1000, height: 800}, nodes: new Map(),
    gone: new Set(), culled: new Set(), selected: new Set(), selectedEdges: new Set(),
    canvasPoint(event) { return {x: (event.clientX - this.view.x) / this.view.zoom, y: (event.clientY - this.view.y) / this.view.zoom} },
    push(event, payload, callback) { calls.push({event, payload}); if (reply) reply(event, payload, callback); else callback({ok: false, error: 'Server refused the file.'}) },
    setTool(value) { this.tool = value },
    selectPending() { if (this.pendingSelect?.every(id => this.nodes.has(id))) { this.selected = new Set(this.pendingSelect); selected.push([...this.pendingSelect]); this.pendingSelect = null } },
    revealNodes(ids) { revealed.push(ids) }, announce(message) { announced.push(message) }, schedule() {},
  }
  canvasElement.fileCanvas = canvas
  const workspace = {el: root, activeCanvas: () => canvasElement, flushEdits: flush || (() => ({ok: true, settled: Promise.resolve()}))}
  const api = mountTextAttachments(workspace)
  const attach = () => root.emit('canvas:attach')
  const choose = files => { input.files = files; return input.emit('change') }
  const drop = (files, extra = {}) => root.emit('drop', {target: canvasRoot, clientX: 500, clientY: 400,
    dataTransfer: {types: ['Files'], files}, ...extra})
  const flushEvent = (withWaiters = true) => {
    const event = new CustomEvent('canvas:flush', {detail: withWaiters ? {waiters: []} : undefined})
    root.dispatchEvent(event); return event
  }
  const addNode = (id = 'attachment', attached = true) => {
    const el = element(); el.className = 'hakushi-node'; el.dataset.id = id
    const shape = element(); shape.className = 'drawing-typography'; if (attached) shape.dataset.attachment = 'text/markdown'
    el.append(shape); canvasElement.append(el)
    const node = {id, el, type: 'shape', label: id}; canvas.nodes.set(id, node); return node
  }
  const status = () => root.querySelector('#attachment-import-status').querySelector('span').textContent
  return {api, workspace, root, input, trigger, canvasRoot, canvasElement, canvas, body, header, controls, dock,
    calls, selected, revealed, announced, downloads, blobs, revoked, observers, attach, choose, drop, flushEvent, addNode, status,
    clicks: () => clicks, dialog: () => body.querySelector('dialog'),
    cleanup() { api.destroyed(); URL.createObjectURL = originalCreate; URL.revokeObjectURL = originalRevoke },
  }
}

function file(content, {name = 'notes.md', type = 'text/markdown', size, read} = {}) {
  const bytes = typeof content === 'string' ? utf8.encode(content) : new Uint8Array(content)
  return {name, type, size: size ?? bytes.byteLength, arrayBuffer: read || (async () => bytes.buffer)}
}
const drawCalls = app => app.calls.filter(call => call.event === 'hakushi:draw')
const assertVisibleBox = (app, box) => {
  assert.equal(box.length, 4)
  assert.deepEqual(box.slice(2), [240, 112])
  const [x, y, width, height] = box
  const bounds = app.canvasRoot.getBoundingClientRect(), view = app.canvas.view
  const left = bounds.left + x * view.zoom, top = bounds.top + y * view.zoom
  assert.ok(left >= app.controls.getBoundingClientRect().right)
  assert.ok(top >= app.header.getBoundingClientRect().bottom)
  assert.ok(left + width * view.zoom <= bounds.right)
  assert.ok(top + height * view.zoom <= app.dock.getBoundingClientRect().top)
}

test('UTF-8 BOM, CRLF, Unicode, and markup survive exactly; draw is one native operation with safe-center geometry', async () => {
  let app
  app = fixture({reply(event, payload, callback) { app.addNode('new-card'); callback({ok: true, drawn: 'new-card'}) }})
  const content = '\ufeff# literal\r\n<script>not executed</script>\n🙂 café\tfin\r'
  await app.attach()
  assert.equal(app.clicks(), 1)
  assert.equal(app.root.dataset.attachmentBusy, 'true')
  await app.choose([file(content, {name: 'source.MARKDOWN', type: 'application/octet-stream'})])
  const payload = drawCalls(app)[0].payload
  assertVisibleBox(app, payload.box)
  assert.deepEqual({...payload, box: undefined}, {tool: 'drawing:attachment', generation: 1, box: undefined,
    attachment: {filename: 'source.MARKDOWN', media_type: 'text/markdown', encoding: 'utf-8', content}})
  assert.equal(drawCalls(app).length, 1)
  assert.deepEqual([...app.canvas.selected], ['new-card'])
  assert.equal(document.activeElement, app.canvas.nodes.get('new-card').el)
  assert.equal(app.root.dataset.attachmentBusy, 'false')
  assert.match(app.status(), /^Attached source.MARKDOWN/)
  assert.equal(app.input.value, '')
  app.cleanup()
})

test('empty text and text MIME without a known extension are valid, source code normalizes to text/plain', async () => {
  for (const candidate of [file('', {name: 'empty.txt', type: 'text/plain'}), file('plain', {name: 'custom.unknown', type: 'text/x-custom'}),
    file('export const value = 1', {name: 'source.ts', type: 'application/octet-stream'})]) {
    const app = fixture({reply(event, payload, callback) { callback({ok: true, drawn: 'new'}) }})
    await app.attach(); await app.choose([candidate])
    assert.equal(drawCalls(app).length, 1)
    assert.equal(drawCalls(app)[0].payload.attachment.content, candidate.size === 0 ? '' : new TextDecoder().decode(await candidate.arrayBuffer()))
    assert.equal(drawCalls(app)[0].payload.attachment.media_type, 'text/plain')
    app.cleanup()
  }
})

test('malformed UTF-8, UTF-16 BOMs, binary controls including C1, and unsupported MIME/extensions never draw', async () => {
  const candidates = [file([0xc3, 0x28]), file([0xef, 0xbb]), file([0xff, 0xfe, 0x61, 0x00]), file('a\0b'),
    file('a\u000bb'), file('a\u000cb'), file('a\u001bb'), file('a\u007fb'), file('a\u0085b'),
    file('not an image', {name: 'image.png', type: 'image/png'})]
  for (const candidate of candidates) {
    const app = fixture()
    await app.attach(); await app.choose([candidate])
    assert.deepEqual(app.calls, [])
    assert.equal(app.root.dataset.attachmentBusy, 'false')
    assert.ok(app.status().length)
    app.cleanup()
  }
})

test('TAB, LF, CR, and non-control Unicode are accepted without replacement or normalization', async () => {
  const content = '\t\n\r\u00a0\u200d\u2060\ufeffé😀'
  const app = fixture({reply(event, payload, callback) { callback({ok: true, drawn: 'new'}) }})
  await app.attach(); await app.choose([file(content)])
  assert.equal(drawCalls(app)[0].payload.attachment.content, content)
  app.cleanup()
})

test('unsafe and overlong UTF-8 filenames are rejected, including controls, paths, and lone surrogates', async () => {
  for (const name of ['../notes.txt', 'folder\\notes.txt', '.', '..', '   ', 'a\nb.txt', 'a\u0085b.txt', '\ud800.txt', `${'é'.repeat(126)}.txt`]) {
    const app = fixture()
    await app.attach(); await app.choose([file('text', {name})])
    assert.deepEqual(app.calls, [])
    assert.match(app.status(), /safe basename/)
    app.cleanup()
  }
})

test('single-file and total attrs use byte limits, empty and exact boundaries valid, oversized files are never read', async () => {
  let reads = 0
  const oversized = fixture({dataset: {attachmentFileLimit: '4'}})
  await oversized.attach()
  await oversized.choose([file('ééé', {read: async () => { reads++; return utf8.encode('ééé').buffer }})])
  assert.equal(reads, 0); assert.deepEqual(oversized.calls, [])
  assert.match(oversized.status(), /4-byte/); oversized.cleanup()
  const total = fixture({dataset: {attachmentFileLimit: '16', attachmentTotalLimit: '3'}})
  await total.attach(); await total.choose([file('éé')])
  assert.deepEqual(total.calls, []); assert.match(total.status(), /total at most 3 bytes/); total.cleanup()
  const boundary = fixture({dataset: {attachmentFileLimit: '4', attachmentTotalLimit: '4'}, reply(event, payload, callback) { callback({ok: true, drawn: 'new'}) }})
  await boundary.attach(); await boundary.choose([file('éé')])
  assert.equal(drawCalls(boundary).length, 1); boundary.cleanup()
})

test('actual buffer length is checked after reading, and missing server limits refuse before choosing', async () => {
  const app = fixture({dataset: {attachmentFileLimit: '4'}})
  await app.attach(); await app.choose([file('abcdef', {size: 1})])
  assert.deepEqual(app.calls, []); assert.match(app.status(), /4-byte/); app.cleanup()
  const missing = fixture({dataset: {attachmentTotalLimit: undefined}})
  await missing.attach()
  assert.equal(missing.clicks(), 0); assert.deepEqual(missing.calls, []); assert.match(missing.status(), /limits are unavailable/)
  missing.cleanup()
})

test('multiple picker and dropped files are refused atomically, and even invalid drops stop native handlers', async () => {
  let reads = 0
  const candidate = file('text', {read: async () => { reads++; return utf8.encode('text').buffer }})
  const app = fixture()
  await app.attach(); await app.choose([candidate, candidate])
  assert.equal(reads, 0); assert.deepEqual(app.calls, [])
  const dropped = await app.drop([candidate, candidate])
  assert.equal(dropped.defaultPrevented, true); assert.equal(dropped.stopped, true)
  assert.equal(reads, 0); assert.deepEqual(app.calls, [])
  const invalid = await app.drop([file('fake', {name: 'image.png', type: 'image/png'})])
  assert.equal(invalid.defaultPrevented, true); assert.equal(invalid.stopped, true)
  assert.deepEqual(app.calls, [])
  app.cleanup()
})

test('native/file busy, readonly, unready, and an active gesture refuse imports before reading or opening', async () => {
  for (const condition of ['nativeBusy', 'fileBusy', 'readonly', 'readiness', 'gesture', 'noCanvas']) {
    const app = fixture()
    if (condition === 'nativeBusy' || condition === 'fileBusy') app.root.dataset[condition] = 'true'
    if (condition === 'readonly') app.canvas.config.readonly = true
    if (condition === 'readiness') app.canvasElement.fileCanvasReady = false
    if (condition === 'gesture') app.canvas.gesture = {kind: 'move'}
    if (condition === 'noCanvas') app.root.dataset.fileMode = 'none'
    let reads = 0
    await app.attach()
    await app.drop([file('text', {read: async () => { reads++; return utf8.encode('text').buffer }})])
    assert.equal(app.clicks(), 0); assert.equal(reads, 0); assert.deepEqual(app.calls, [])
    assert.equal(app.root.dataset.attachmentBusy, 'false')
    app.cleanup()
  }
})

test('drawing-surface drop uses native world coordinates, chrome uses the visible center, and unrelated drags are untouched', async () => {
  const app = fixture({reply(event, payload, callback) { callback({ok: true, drawn: 'new'}) }})
  await app.drop([file('text')])
  assert.deepEqual(drawCalls(app)[0].payload.box, [240, 215, 240, 112])
  await app.drop([file('text')], {target: app.dock})
  assertVisibleBox(app, drawCalls(app)[1].payload.box)
  const drag = await app.root.emit('dragover', {dataTransfer: {types: ['text/plain'], items: [{kind: 'string'}]}})
  assert.equal(drag.defaultPrevented, false); assert.equal(drag.stopped, undefined)
  const over = await app.root.emit('dragover', {dataTransfer: {types: ['Files'], files: []}})
  assert.equal(over.defaultPrevented, true); assert.equal(over.stopped, true); assert.equal(over.dataTransfer.dropEffect, 'copy')
  app.cleanup()
})

test('picker cancellation is quiet, same-file reselection is allowed, and flush waiters settle without drawing', async () => {
  const app = fixture()
  await app.attach()
  const flush = app.flushEvent()
  await app.input.emit('cancel')
  assert.deepEqual(await Promise.all(flush.detail.waiters), [true])
  assert.equal(app.root.dataset.attachmentBusy, 'false'); assert.equal(app.status(), '')
  assert.equal(document.activeElement, app.trigger); assert.deepEqual(app.calls, [])
  await app.attach(); await app.choose([])
  assert.equal(app.clicks(), 2); assert.equal(app.root.dataset.attachmentBusy, 'false')
  app.cleanup()
})

test('generation changes before choosing never read, mid-read never post, and old completions cannot reset a new import', async () => {
  let reads = 0
  const before = fixture()
  await before.attach(); before.root.dataset.generation = '2'; before.api.updated()
  await before.choose([file('text', {read: async () => { reads++; return utf8.encode('text').buffer }})])
  assert.equal(reads, 0); assert.deepEqual(before.calls, []); assert.equal(before.status(), '')
  before.cleanup()
  const buffer = deferred(), app = fixture()
  await app.attach()
  const importing = app.choose([file('text', {read: () => buffer.promise})])
  const waiters = app.flushEvent()
  app.root.dataset.generation = '2'; app.api.updated()
  assert.deepEqual(await Promise.all(waiters.detail.waiters), [true])
  await app.attach()
  buffer.resolve(utf8.encode('text').buffer); await importing
  assert.deepEqual(app.calls, []); assert.equal(app.root.dataset.attachmentBusy, 'true')
  await app.input.emit('cancel'); app.cleanup()
})

test('a late successful draw reply from an old generation cannot select, focus, announce success, or affect current busy state', async () => {
  let deliver
  const app = fixture({reply(event, payload, callback) { deliver = callback }})
  await app.attach()
  const importing = app.choose([file('text')]); await settle()
  assert.equal(drawCalls(app).length, 1)
  app.root.dataset.generation = '2'; app.api.updated(); await app.attach()
  deliver({ok: true, drawn: 'stale-card'}); await importing
  assert.equal(app.canvas.pendingSelect, undefined); assert.deepEqual(app.selected, [])
  assert.equal(app.status(), ''); assert.equal(app.root.dataset.attachmentBusy, 'true')
  await app.input.emit('cancel'); app.cleanup()
})

test('pending import flush waits through decoding and native reply; nativeBusy from save/new does not deadlock it', async () => {
  const buffer = deferred(); let deliver
  const app = fixture({reply(event, payload, callback) { deliver = callback }})
  await app.attach()
  const importing = app.choose([file('text', {read: () => buffer.promise})])
  const flush = app.flushEvent(); let settled = false
  const waited = Promise.all(flush.detail.waiters).then(() => { settled = true })
  app.root.dataset.nativeBusy = 'true'
  buffer.resolve(utf8.encode('text').buffer); await settle()
  assert.equal(settled, false); assert.equal(drawCalls(app).length, 1)
  deliver({ok: true, drawn: 'new'}); await importing; await waited
  assert.equal(settled, true); assert.equal(app.root.dataset.attachmentBusy, 'false')
  app.cleanup()
})

test('preliminary Open flush is refused while import is pending, and a failed import rejects save waiters without save-error events', async () => {
  const app = fixture()
  await app.attach()
  const open = app.flushEvent(false)
  assert.equal(open.defaultPrevented, true)
  const waiting = app.flushEvent()
  const rejected = assert.rejects(Promise.all(waiting.detail.waiters), /text file was not attached/)
  await app.choose([file('text')]); await rejected
  assert.deepEqual(app.calls.map(call => call.event), ['hakushi:draw'])
  assert.match(app.status(), /Server refused/)
  app.cleanup()
})

test('an unsuccessful current edit flush blocks the picker, asynchronous edit failure blocks draw', async () => {
  const blocked = fixture({flush: () => ({ok: false})})
  await blocked.attach(); assert.equal(blocked.clicks(), 0); assert.deepEqual(blocked.calls, []); blocked.cleanup()
  const edits = deferred(), app = fixture({flush: () => ({ok: true, settled: edits.promise})})
  await app.attach()
  const importing = app.choose([file('text')])
  edits.reject(new Error('Edit refused')); await importing
  assert.deepEqual(app.calls, []); assert.match(app.status(), /current canvas edit could not finish/)
  app.cleanup()
})

test('ok:true, a nonempty drawn id, and no error are all required before selecting or reporting success', async () => {
  for (const reply of [{drawn: 'wrong'}, {ok: false, drawn: 'wrong'}, {ok: true}, {ok: true, drawn: ''},
    {ok: true, drawn: 'wrong', error: 'Graph total exceeded'}]) {
    const app = fixture({reply(event, payload, callback) { callback(reply) }})
    await app.attach(); await app.choose([file('text')])
    assert.deepEqual(app.selected, []); assert.equal(app.canvas.pendingSelect, undefined)
    assert.equal(app.root.dataset.attachmentBusy, 'false'); assert.ok(!app.status().startsWith('Attached '))
    app.cleanup()
  }
})

test('streamed success uses pending native selection and focuses only once the node exists', async () => {
  const app = fixture({reply(event, payload, callback) { callback({ok: true, drawn: 'later'}) }})
  await app.attach(); await app.choose([file('text')])
  assert.deepEqual(app.canvas.pendingSelect, ['later']); assert.deepEqual(app.selected, [])
  const node = app.addNode('later'); app.api.updated()
  assert.deepEqual([...app.canvas.selected], ['later']); assert.equal(document.activeElement, node.el)
  assert.equal(app.canvas.lastFocus, node.el); assert.deepEqual(app.revealed, [['later']])
  app.cleanup()
})

test('Enter/F2 and double-click capture attachment preview, literal pre and exact plain-text download never mutate the graph', async () => {
  const content = '\ufeff# Source\r\n<script>window.pwned=1</script>\n![remote](https://example.invalid/image)\t🙂'
  const attachment = {filename: 'source.md', media_type: 'text/markdown', encoding: 'utf-8', content, future: {retained: true}}
  const app = fixture({reply(event, payload, callback) { callback({ok: true, attachment}) }})
  const node = app.addNode()
  node.el.focus()
  const event = await app.root.emit('keydown', {target: node.el, key: 'Enter'})
  assert.equal(event.defaultPrevented, true); assert.equal(event.stopped, true)
  const dialog = app.dialog(), pre = dialog.querySelector('pre')
  assert.equal(dialog.open, true); assert.equal(pre.textContent, content); assert.equal(pre.children.length, 0)
  assert.equal(dialog.getAttribute('role'), null); assert.equal(dialog.getAttribute('aria-modal'), null)
  assert.equal(dialog.getAttribute('aria-labelledby'), dialog.querySelector('h2').id)
  assert.equal(dialog.querySelector('form').method, 'dialog')
  assert.equal(document.activeElement, dialog.querySelector('.attachment-preview-close'))
  assert.equal(dialog.querySelector('.attachment-preview-close').autofocus, true)
  await dialog.querySelector('.attachment-preview-download').emit('click')
  assert.equal(app.blobs[0].type, 'text/plain')
  assert.deepEqual(new Uint8Array(await app.blobs[0].arrayBuffer()), utf8.encode(content))
  assert.equal(app.downloads[0].filename, 'source.md')
  assert.match(dialog.querySelector('.attachment-preview-status').textContent, /Download started.*cannot be confirmed/)
  dialog.close()
  assert.equal(app.dialog(), null); assert.equal(document.activeElement, node.el)
  const f2 = await app.root.emit('keydown', {target: node.el, key: 'F2'})
  assert.equal(f2.stopped, true); app.dialog().close()
  const double = await app.root.emit('dblclick', {target: node.el.children[0]})
  assert.equal(double.stopped, true); app.dialog().close()
  assert.deepEqual(app.calls.map(call => call.event), ['drawing:attachment-read', 'drawing:attachment-read', 'drawing:attachment-read'])
  assert.deepEqual(app.calls[0].payload, {generation: 1, node: node.id})
  assert.deepEqual(drawCalls(app), [])
  assert.deepEqual(attachment, {filename: 'source.md', media_type: 'text/markdown', encoding: 'utf-8', content, future: {retained: true}})
  app.cleanup()
})

test('pointer-captured double-click hit-tests the attachment instead of opening the native filename editor', async () => {
  const app = fixture({reply(event, payload, callback) {
    callback({ok: true, attachment: {filename: 'notes.txt', media_type: 'text/plain', encoding: 'utf-8', content: 'literal'}})
  }})
  const node = app.addNode()
  let point
  document.elementFromPoint = (x, y) => { point = [x, y]; return node.el.children[0] }
  const event = await app.root.emit('dblclick', {target: app.canvasRoot, clientX: 150, clientY: 220})
  assert.deepEqual(point, [150, 220])
  assert.equal(event.defaultPrevented, true); assert.equal(event.stopped, true)
  assert.equal(app.dialog().querySelector('pre').textContent, 'literal')
  assert.deepEqual(app.calls.map(call => call.event), ['drawing:attachment-read'])
  app.dialog().close()
  const outside = element('button')
  document.elementFromPoint = () => outside
  const control = await app.root.emit('dblclick', {target: app.canvasRoot, clientX: 12, clientY: 12})
  assert.equal(control.defaultPrevented, false)
  app.cleanup()
})

test('preview leaves descendant controls, IME/modifiers, direct editing modes, gestures, and ordinary nodes to native handlers', async () => {
  const app = fixture()
  const node = app.addNode(), ordinary = app.addNode('ordinary', false), button = element('button')
  node.el.append(button)
  for (const extra of [{target: button}, {target: ordinary.el}, {target: node.el, isComposing: true},
    {target: node.el, ctrlKey: true}, {target: node.el, shiftKey: true}, {target: node.el, repeat: true}]) {
    const event = await app.root.emit('keydown', {key: 'Enter', ...extra})
    assert.equal(event.defaultPrevented, false)
  }
  for (const condition of ['direct', 'tool', 'gesture']) {
    if (condition === 'direct') app.canvasElement.directKeyboard = {active: true}
    if (condition === 'tool') app.canvas.tool = {tool: 'rect'}
    if (condition === 'gesture') app.canvas.gesture = {kind: 'move'}
    const event = await app.root.emit('keydown', {target: node.el, key: 'F2'})
    assert.equal(event.defaultPrevented, false)
    app.canvasElement.directKeyboard = null; app.canvas.tool = null; app.canvas.gesture = null
  }
  assert.deepEqual(app.calls, []); app.cleanup()
})

test('root Enter previews a sole selected attachment but not a mixed edge selection', async () => {
  const attachment = {filename: 'empty.txt', media_type: 'text/plain', encoding: 'utf-8', content: ''}
  const app = fixture({reply(event, payload, callback) { callback({ok: true, attachment}) }})
  const node = app.addNode(); app.canvas.selected.add(node.id); app.canvasRoot.focus()
  const event = await app.root.emit('keydown', {target: app.canvasRoot, key: 'Enter'})
  assert.equal(event.stopped, true); assert.match(app.dialog().querySelector('.attachment-preview-status').textContent, /empty/)
  app.dialog().close(); app.canvas.selectedEdges.add('edge')
  const mixed = await app.root.emit('keydown', {target: app.canvasRoot, key: 'Enter'})
  assert.equal(mixed.defaultPrevented, false); app.cleanup()
})

test('generation changes and dismissal discard late preview reads without reopening or downloading', async () => {
  let deliver
  const app = fixture({reply(event, payload, callback) { deliver = callback }})
  const node = app.addNode()
  const reading = app.root.emit('keydown', {target: node.el, key: 'Enter'})
  assert.equal(app.dialog().open, true)
  app.root.dataset.generation = '2'; app.api.updated()
  assert.equal(app.dialog(), null)
  deliver({ok: true, attachment: {filename: 'stale.txt', media_type: 'text/plain', encoding: 'utf-8', content: 'stale'}})
  await reading
  assert.equal(app.dialog(), null); assert.deepEqual(app.downloads, [])
  const dismissed = app.root.emit('keydown', {target: node.el, key: 'F2'})
  app.dialog().close()
  deliver({ok: true, attachment: {filename: 'late.txt', media_type: 'text/plain', encoding: 'utf-8', content: 'late'}})
  await dismissed
  assert.equal(app.dialog(), null); assert.deepEqual(app.downloads, [])
  app.cleanup()
})

test('read failures and unsafe returned metadata remain in the read-only modal with download disabled', async () => {
  for (const reply of [{ok: false, error: 'Attachment removed'}, {ok: true, attachment: {filename: '../unsafe.txt', media_type: 'text/plain', encoding: 'utf-8', content: 'text'}},
    {ok: true, attachment: {filename: 'binary.txt', media_type: 'text/plain', encoding: 'utf-8', content: '\0'}}]) {
    const app = fixture({reply(event, payload, callback) { callback(reply) }})
    const node = app.addNode()
    await app.root.emit('keydown', {target: node.el, key: 'Enter'})
    assert.equal(app.dialog().querySelector('.attachment-preview-download').disabled, true)
    assert.equal(app.dialog().querySelector('pre').textContent, '')
    assert.ok(app.dialog().querySelector('.attachment-preview-status').textContent)
    assert.deepEqual(drawCalls(app), []); app.cleanup()
  }
})

test('failed downloads report only initiation failure, never dispatch a graph or persistence event', async () => {
  const app = fixture({downloadError: new Error('Downloads blocked'), reply(event, payload, callback) {
    callback({ok: true, attachment: {filename: 'notes.txt', media_type: 'text/plain', encoding: 'utf-8', content: 'text'}})
  }})
  await app.root.emit('keydown', {target: app.addNode().el, key: 'Enter'})
  await app.dialog().querySelector('.attachment-preview-download').emit('click')
  assert.deepEqual(app.downloads, []); assert.match(app.dialog().querySelector('.attachment-preview-status').textContent, /Could not start download: Downloads blocked/)
  assert.deepEqual(app.calls.map(call => call.event), ['drawing:attachment-read'])
  app.cleanup()
})

test('status is dismissible and stable across updates, input replacement rebinds, teardown resolves imports and removes listeners and modal', async () => {
  const app = fixture()
  await app.attach(); await app.choose([file('\0')])
  const status = app.root.querySelector('#attachment-import-status'), dismiss = status.querySelector('button'), span = status.querySelector('span')
  app.api.updated(); app.api.updated()
  assert.equal(status.querySelector('span'), span); assert.equal(status.querySelector('button'), dismiss)
  dismiss.focus()
  await dismiss.emit('click'); assert.equal(status.hidden, true)
  assert.equal(document.activeElement, app.trigger)
  await app.attach()
  const waiters = app.flushEvent()
  const replacement = element('input'); replacement.id = 'attachment-file-input'
  app.input.remove(); app.root.append(replacement); app.api.updated()
  assert.deepEqual(await Promise.all(waiters.detail.waiters), [true])
  assert.equal(app.input.listenerCount(), 0); assert.equal(replacement.listenerCount(), 2)
  await app.attach()
  const cancelled = app.flushEvent()
  app.cleanup()
  assert.deepEqual(await Promise.all(cancelled.detail.waiters), [true])
  assert.equal(app.root.listenerCount(), 0); assert.equal(replacement.listenerCount(), 0)
  assert.equal(app.root.dataset.attachmentBusy, 'false'); assert.equal(app.root.querySelector('#attachment-import-status'), null)
  assert.equal(app.observers[0].disconnected, true)
})
