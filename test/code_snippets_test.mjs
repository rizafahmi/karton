import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'
const literal = await readFile(new URL('../assets/js/literal_source.js', import.meta.url), 'utf8')
const literalURL = `data:text/javascript;base64,${Buffer.from(literal).toString('base64')}`
const source = (await readFile(new URL('../assets/js/code_snippets.js', import.meta.url), 'utf8')).replace("'./literal_source.js'", JSON.stringify(literalURL))
const {mountCodeSnippets, codeIsClipped} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
function element(tag) {
  const handlers = new Map(), attrs = new Map()
  const el = {tag, children: [], dataset: {}, style: {}, isConnected: true, textContent: '', value: '', selectionStart: 0, selectionEnd: 0,
    setAttribute(key, value) { attrs.set(key, value) }, removeAttribute(key) { attrs.delete(key) }, getAttribute(key) { return attrs.get(key) },
    addEventListener(key, fn) { handlers.set(key, [...handlers.get(key) || [], fn]) }, removeEventListener() {},
    append(...items) { el.children.push(...items); for (const item of items) item.parent = el },
    replaceChildren(...items) { el.children = []; el.append(...items) },
    remove() { el.isConnected = false; if (el.parent) el.parent.children = el.parent.children.filter(item => item !== el) },
    focus() { document.activeElement = el }, contains(target) { return target === el || el.children.some(child => child.contains?.(target)) },
    setSelectionRange(start, end) { el.selectionStart = start; el.selectionEnd = end },
    closest(selector) { return selector === '#workspace' ? el.workspace : null }, querySelector() { return null }, querySelectorAll() { return [] },
    emit(type, options = {}) { const event = {target: el, preventDefault() { this.defaultPrevented = true }, stopPropagation() { this.propagationStopped = true }, stopImmediatePropagation() { this.propagationStopped = true }, ...options}; for (const fn of handlers.get(type) || []) fn(event); return event },
  }
  return el
}
function fixture({version = '2', code = '\ufeffa\r\nb\rc\n', total = '1048576', WorkerClass} = {}) {
  const root = element('root'), workspace = element('workspace'), ui = element('ui')
  workspace.dataset = {generation: '1', documentVersion: version, codeTotalLimit: total, codeWorker: WorkerClass ? '/worker.js' : ''}; root.workspace = workspace
  globalThis.document = {activeElement: root, createElement: element, hasFocus: () => true, createDocumentFragment: () => element('fragment')}
  let mutationCallback
  globalThis.MutationObserver = class { constructor(callback) { mutationCallback = callback } observe() {} disconnect() {} }
  globalThis.Worker = WorkerClass
  const literal = {dataset: {codeContent: JSON.stringify(code), codeLanguage: 'auto', codeSize: 'm'}, querySelector: () => null}
  const el = element('node'); el.dataset.id = 'a'; el.querySelector = selector => selector === '[data-code-node]' ? literal : null
  const node = {id: 'a', type: 'code', x: 0, y: 0, width: 320, height: 180, el}
  const calls = [], messages = []
  const canvas = {root, ui, config: {}, nodes: new Map([['a', node]]), gone: new Set(), focusedNode: () => node, announce: message => messages.push(message), setTool(tool) { this.tool = tool }, selectPending() {}, push(event, payload, callback) { calls.push({event, payload, callback}) }}
  const api = mountCodeSnippets(canvas)
  const descendants = el => el.children.flatMap(child => [child, ...descendants(child)])
  return {api, canvas, calls, messages, workspace, node, literal,
    input: () => descendants(ui).find(el => el.tag === 'textarea'),
    feedback: () => descendants(ui).find(el => el.className === 'drawing-code-feedback'),
    button: text => descendants(ui).find(el => el.tag === 'button' && el.textContent === text),
    fitOption: () => descendants(ui).find(el => el.tag === 'input' && el.type === 'checkbox'),
    mutate() { mutationCallback([]) },
    flush(waiters = true) { return workspace.emit('canvas:flush', waiters ? {detail: {waiters: []}} : {}) },
    activate() { root.emit('keydown', {key: 'F2'}) },
  }
}
test('public F2 source editing is a no-op until one literal source transaction commits', async () => {
  const f = fixture(); f.activate()
  const input = f.input(); assert.equal(input.value, '\ufeffa\nb\nc\n'); assert.deepEqual(f.calls, [])
  input.setSelectionRange(3, 4)
  input.emit('paste', {clipboardData: {getData: () => 'x\r\ny\r😀'}})
  const flush = f.flush()
  assert.equal(flush.defaultPrevented, undefined)
  assert.equal(flush.detail.waiters.length, 1)
  assert.equal(f.calls.length, 1)
  assert.equal(f.calls[0].event, 'hakushi:edit')
  assert.equal(f.calls[0].payload.content, '\ufeffa\r\nx\r\ny\r😀\rc\n')
  let settled = false; flush.detail.waiters[0].then(() => { settled = true })
  await Promise.resolve(); assert.equal(settled, false)
  f.calls[0].callback({ok: true}); await flush.detail.waiters[0]
  assert.equal(f.workspace.codeDraft, false); assert.equal(f.input(), undefined)
  f.api.destroy()
})
test('invalid UTF-8 draft vetoes general and preliminary flush and remains editable', () => {
  const f = fixture(); f.activate(); const input = f.input()
  input.emit('paste', {clipboardData: {getData: () => '\ud800'}})
  assert.equal(f.flush().defaultPrevented, true)
  assert.equal(f.flush(false).defaultPrevented, true)
  assert.equal(input.getAttribute('aria-invalid'), 'true')
  assert.equal(f.calls.length, 0); assert.equal(f.workspace.codeDraft, true)
  input.emit('keydown', {key: 'Escape'})
  assert.equal(f.input(), input); assert.equal(f.calls.length, 0)
  f.api.destroy()
})
test('creation is a local draft followed by exactly one native draw; v1 cannot create', async () => {
  const f = fixture()
  f.canvas.push('hakushi:draw', {tool: 'code:block', box: [10, 20, 320, 180]})
  assert.equal(f.calls.length, 0)
  f.input().emit('paste', {clipboardData: {getData: () => '\tconst x = 1\r\n'}})
  const flush = f.flush(); assert.equal(f.calls.length, 1)
  assert.equal(f.calls[0].event, 'hakushi:draw')
  assert.equal(f.calls[0].payload.style.content, '\tconst x = 1\r\n')
  f.calls[0].callback({ok: true, drawn: 'new'}); await flush.detail.waiters[0]; f.api.destroy()
  const legacy = fixture({version: '1'}); legacy.canvas.push('hakushi:draw', {tool: 'code:block'})
  assert.equal(legacy.input(), undefined); assert.equal(legacy.calls.length, 0); assert.ok(legacy.feedback()); legacy.api.destroy()
})
test('v1 Code selection stays in pointer mode and offers the document workflow without changing the graph', () => {
  const f = fixture({version: '1'})
  let menuOpen = false
  f.workspace.dispatchEvent = () => true
  f.workspace.querySelector = selector => selector === '#file-menu-toggle' ? {getAttribute: () => 'false', click() { menuOpen = true }} : null
  f.canvas.setTool('code:block')
  assert.equal(f.canvas.tool, null)
  assert.equal(f.input(), undefined)
  assert.equal(f.calls.length, 0)
  const feedback = f.feedback()
  const action = feedback.children.find(el => el.tag === 'button' && el.textContent !== 'Dismiss')
  action.emit('click')
  assert.equal(menuOpen, true)
  assert.equal(f.feedback(), undefined)
  assert.equal(f.calls.length, 0)
  f.api.destroy()
})
test('native click placement opens a local draft and commits nonzero geometry at the chosen position', async () => {
  const f = fixture()
  f.canvas.setTool('code:block')
  f.canvas.push('hakushi:draw', {tool: 'code:block', box: [120, 240, 0, 0]})
  assert.equal(f.calls.length, 0)
  const input = f.input()
  input.emit('paste', {clipboardData: {getData: () => 'const clicked = true;'}})
  const flush = f.flush()
  assert.equal(f.calls.length, 1)
  const {box, style} = f.calls[0].payload
  assert.deepEqual(box.slice(0, 2), [120, 240])
  assert.ok(box[2] > 0 && box[3] > 0)
  assert.equal(style.content, 'const clicked = true;')
  f.calls[0].callback({ok: true, drawn: 'clicked'})
  await flush.detail.waiters[0]
  assert.equal(f.input(), undefined)
  f.api.destroy()
})
test('moving from source to Cancel never commits the draft during the transient body-focus interval', async () => {
  const f = fixture()
  f.canvas.push('hakushi:draw', {tool: 'code:block', box: [0, 0, 320, 180]})
  const input = f.input(), editor = input.parent
  input.emit('paste', {clipboardData: {getData: () => 'must not be added'}})
  const cancel = f.button('Cancel')
  document.activeElement = f.canvas.root
  editor.emit('focusout', {relatedTarget: cancel})
  await Promise.resolve()
  assert.equal(f.calls.length, 0)
  cancel.emit('click')
  assert.equal(f.input(), undefined)
  assert.equal(f.workspace.codeDraft, false)
  assert.equal(f.calls.length, 0)
  f.api.destroy()
})
test('pending fit choice blocks preliminary file replacement without committing and can be withdrawn', () => {
  const f = fixture()
  f.activate()
  const input = f.input(), fit = f.fitOption()
  fit.checked = true
  assert.equal(f.flush(false).defaultPrevented, true)
  assert.equal(f.input(), input)
  assert.equal(f.calls.length, 0)
  fit.checked = false
  assert.equal(f.flush(false).defaultPrevented, undefined)
  assert.equal(f.input(), undefined)
  assert.equal(f.calls.length, 0)
  f.api.destroy()
})
test('source undo precedes graph history, Tab uses two spaces, and composition owns Enter', () => {
  const f = fixture({code: 'a\r\nb'}); f.activate(); const input = f.input()
  input.setSelectionRange(0, 0); input.emit('keydown', {key: 'Tab'})
  assert.equal(input.value, '  a\nb')
  input.emit('keydown', {key: 'z', ctrlKey: true})
  assert.equal(input.value, 'a\nb')
  input.setSelectionRange(1, 1); input.emit('keydown', {key: 'Enter'})
  assert.equal(input.value, 'a\n\nb')
  input.emit('compositionstart'); const composing = input.emit('keydown', {key: 'Enter', isComposing: true})
  assert.equal(composing.defaultPrevented, undefined); assert.equal(f.flush().defaultPrevented, true)
  input.emit('compositionend'); const flush = f.flush()
  assert.equal(f.calls[0].payload.content, 'a\r\n\r\nb')
  f.calls[0].callback({ok: true}); return flush.detail.waiters[0].then(() => f.api.destroy())
})
test('server rejection retains the draft and rejects asynchronous snapshot waiters', async () => {
  const f = fixture(); f.activate(); f.input().emit('paste', {clipboardData: {getData: () => 'x'}})
  const flush = f.flush(), rejected = assert.rejects(flush.detail.waiters[0], /quota refused/)
  f.calls[0].callback({ok: false, error: 'quota refused'}); await rejected
  assert.equal(f.workspace.codeDraft, true); assert.equal(f.input().readOnly, false)
  f.api.destroy()
})
test('generation replacement rejects a late commit without touching the new board', async () => {
  const f = fixture(); f.activate(); f.input().emit('paste', {clipboardData: {getData: () => 'x'}})
  const flush = f.flush(), rejected = assert.rejects(flush.detail.waiters[0], /Canvas changed/)
  f.workspace.dataset.generation = '2'; f.calls[0].callback({ok: true}); await rejected; f.api.destroy()
})
test('total quota is independent from per-source quota and includes other code nodes', () => {
  const f = fixture({total: '5', code: '1234'}); f.activate()
  f.canvas.nodes.set('b', {id: 'b', type: 'code', el: {querySelector: () => ({dataset: {codeContent: JSON.stringify('12')}})}})
  assert.equal(f.flush().defaultPrevented, true); assert.equal(f.calls.length, 0); f.api.destroy()
})
test('direct export clipping boundary checks both horizontal and vertical hidden source', () => {
  assert.equal(codeIsClipped({querySelectorAll: () => [{scrollHeight: 100, clientHeight: 100, scrollWidth: 201, clientWidth: 100}]}), true)
  assert.equal(codeIsClipped({querySelectorAll: () => [{scrollHeight: 201, clientHeight: 100, scrollWidth: 100, clientWidth: 100}]}), true)
  assert.equal(codeIsClipped({querySelectorAll: () => [{scrollHeight: 100, clientHeight: 100, scrollWidth: 100, clientWidth: 100}]}), false)
})

test('worker replies are source/identity/generation scoped and token text cannot become HTML', async () => {
  let instance
  class WorkerDouble {
    constructor() { instance = this; this.handlers = new Map(); this.sent = [] }
    addEventListener(name, fn) { this.handlers.set(name, fn) }
    postMessage(data) { this.sent.push(data) }
    terminate() {}
    deliver(data) { this.handlers.get('message')({data}) }
  }
  const source = '<img src=x onerror=alert(1)>'
  const f = fixture({WorkerClass: WorkerDouble, code: source})
  const pre = element('pre'), code = element('code'), status = element('p')
  pre.scrollHeight = pre.clientHeight = 100; pre.scrollWidth = pre.clientWidth = 200
  f.literal.querySelector = selector => selector === '.drawing-code-source' ? pre : selector === '.drawing-code-source code' ? code : selector === '.drawing-code-highlight-status' ? status : null
  await Promise.resolve()
  const request = instance.sent[0]
  assert.equal(request.source, source)
  instance.deliver({...request, revision: 'obsolete', status: 'wrong', tokens: [{text: source}]})
  assert.equal(code.children.length, 0)
  instance.deliver({...request, status: 'javascript', tokens: [{text: source, color: '#123456'}]})
  assert.equal(code.children[0].children[0].textContent, source)
  assert.equal(code.children[0].children[0].tag, 'span')
  assert.equal(code.children[0].children[0].style.color, '#123456')
  const before = code.children[0]
  f.workspace.dataset.generation = '2'
  instance.deliver({...request, status: 'late', tokens: [{text: source}]})
  assert.equal(code.children[0], before)
  f.api.destroy()
})

test('worker failure is visibly unavailable, not a successful plain-text highlight', async () => {
  let instance
  class WorkerDouble {
    constructor() { instance = this; this.handlers = new Map() }
    addEventListener(name, fn) { this.handlers.set(name, fn) }
    postMessage() {}
    terminate() {}
  }
  const f = fixture({WorkerClass: WorkerDouble})
  const status = element('p')
  f.literal.querySelector = selector => selector === '.drawing-code-highlight-status' ? status : null
  await Promise.resolve()
  assert.equal(status.textContent, 'Highlighting…')
  instance.handlers.get('error')()
  assert.match(status.textContent, /unavailable/)
  f.api.destroy()
})

test('an untouched existing mixed-ending source exits without creating graph history', async () => {
  const f = fixture(); f.activate()
  const flush = f.flush()
  await Promise.all(flush.detail.waiters)
  assert.equal(f.calls.length, 0); assert.equal(f.workspace.codeDraft, false)
  f.api.destroy()
})

test('source changes cancel a stale editor and veto the pending snapshot rather than saving an old source', async () => {
  const f = fixture(); f.activate()
  f.input().emit('paste', {clipboardData: {getData: () => 'pending'}})
  f.literal.dataset.codeContent = JSON.stringify('new authoritative source')
  const flush = f.flush()
  await assert.rejects(flush.detail.waiters[0], /source changed/)
  assert.equal(f.calls.length, 0)
  assert.equal(f.workspace.codeDraft, false)
  f.api.destroy()
})

test('invalid source has a documented keyboard route to language and Cancel controls', () => {
  const f = fixture(); f.activate()
  const input = f.input()
  input.emit('paste', {clipboardData: {getData: () => '\u0000'}})
  input.emit('keydown', {key: 'Enter', ctrlKey: true})
  assert.equal(document.activeElement.tag, 'select')
  assert.equal(f.calls.length, 0)
  assert.equal(f.workspace.codeDraft, true)
  f.api.destroy()
})

test('public history controls undo the literal draft before any graph history', () => {
  const f = fixture({code: 'a\r\nb'}); f.activate()
  const input = f.input()
  input.setSelectionRange(1, 1); input.emit('paste', {clipboardData: {getData: () => 'X\rY'}})
  f.canvas.undo(); assert.equal(input.value, 'a\nb')
  f.canvas.redo(); assert.equal(input.value, 'aX\nY\nb')
  assert.equal(f.calls.length, 0)
  f.api.destroy()
})

test('native node rereads on the same DOM/source retain an active literal draft', async () => {
  let instance
  class WorkerDouble {
    constructor() { instance = this; this.handlers = new Map(); this.sent = [] }
    addEventListener(name, fn) { this.handlers.set(name, fn) }
    postMessage(data) { this.sent.push(data) }
    terminate() {}
    deliver(data) { this.handlers.get('message')({data}) }
  }
  const source = 'const x = 1;\r\n'
  const f = fixture({WorkerClass: WorkerDouble, code: source})
  const pre = element('pre'), code = element('code'), status = element('p')
  pre.scrollHeight = pre.clientHeight = 100; pre.scrollWidth = pre.clientWidth = 200
  f.literal.querySelector = selector => selector === '.drawing-code-source' ? pre : selector === '.drawing-code-source code' ? code : selector === '.drawing-code-highlight-status' ? status : null
  await Promise.resolve()
  const request = instance.sent[0]
  f.activate()
  const input = f.input()
  input.setSelectionRange(0, 0)
  input.emit('paste', {clipboardData: {getData: () => '// draft\r'}})
  f.canvas.nodes.set('a', {...f.node})
  f.mutate()
  await Promise.resolve()
  assert.equal(f.input(), input)
  instance.deliver({...request, status: 'javascript', tokens: [{text: source, color: '#123456'}]})
  f.canvas.nodes.set('a', {...f.node})
  f.mutate()
  await Promise.resolve()
  assert.equal(f.input(), input)
  const flush = f.flush()
  assert.equal(f.calls[0].payload.content, '// draft\r' + source)
  f.calls[0].callback({ok: true})
  await flush.detail.waiters[0]
  f.api.destroy()
})

test('a native reread does not count the edited source twice at the total quota', async () => {
  const f = fixture({code: '1234', total: '5'})
  const otherSource = {dataset: {codeContent: JSON.stringify('5'), codeLanguage: 'auto'}, querySelector: () => null}
  f.canvas.nodes.set('b', {id: 'b', type: 'code', el: {querySelector: selector => selector === '[data-code-node]' ? otherSource : null}})
  f.activate()
  const input = f.input()
  input.setSelectionRange(0, 1)
  input.emit('paste', {clipboardData: {getData: () => 'x'}})
  f.canvas.nodes.set('a', {...f.node})
  f.mutate()
  await Promise.resolve()
  const flush = f.flush()
  assert.equal(flush.defaultPrevented, undefined)
  assert.equal(f.calls[0].payload.content, 'x234')
  f.calls[0].callback({ok: true})
  await flush.detail.waiters[0]
  f.api.destroy()
})

test('unmeasurable hidden code cannot be declared a complete export', () => {
  assert.equal(codeIsClipped({querySelectorAll: () => [{scrollHeight: 0, clientHeight: 0, scrollWidth: 0, clientWidth: 0}]}), true)
})

test('overflow source scrolls natively without canvas panning while zoom and Space keep native routing', () => {
  const f = fixture(), pre = element('pre')
  Object.assign(pre, {scrollWidth: 600, clientWidth: 200, scrollHeight: 400, clientHeight: 140})
  pre.closest = selector => selector === '.drawing-code-source' ? pre : null
  const wheel = options => f.canvas.root.emit('wheel', {target: pre, deltaX: 0, deltaY: 60, ...options})
  const scrolling = wheel()
  assert.equal(scrolling.propagationStopped, true)
  assert.equal(scrolling.defaultPrevented, undefined)
  assert.equal(wheel({deltaX: 60, deltaY: 0}).propagationStopped, true)
  assert.equal(wheel({shiftKey: true}).propagationStopped, true)
  assert.equal(wheel({ctrlKey: true}).propagationStopped, undefined)
  assert.equal(wheel({metaKey: true}).propagationStopped, undefined)
  f.canvas.space = true
  assert.equal(wheel().propagationStopped, undefined)
  f.canvas.space = false
  pre.scrollWidth = pre.clientWidth; pre.scrollHeight = pre.clientHeight
  assert.equal(wheel().propagationStopped, undefined)
  f.api.destroy()
})

test('source text stays on the native drag path while scrollbar tracks retain native pointer handling', () => {
  const f = fixture(), pre = element('pre')
  Object.assign(pre, {offsetWidth: 220, clientWidth: 200, offsetHeight: 160, clientHeight: 140})
  pre.closest = selector => selector === '.drawing-code-source' ? pre : null
  const down = options => f.canvas.root.emit('pointerdown', {target: pre, offsetX: 80, offsetY: 60, ...options})
  assert.equal(down().propagationStopped, undefined)
  assert.equal(down({offsetX: 205}).propagationStopped, true)
  assert.equal(down({offsetY: 145}).propagationStopped, true)
  assert.equal(down({target: {closest: () => pre}, offsetX: 205}).propagationStopped, undefined)
  f.canvas.space = true
  assert.equal(down({offsetX: 205}).propagationStopped, undefined)
  f.api.destroy()
})
