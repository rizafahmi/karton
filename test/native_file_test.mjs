import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'
const source = await readFile(new URL('../assets/js/native_file.js', import.meta.url), 'utf8')
const {mountNativeFile} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return {promise, resolve} }

function fixture({flush = () => ({ok: true, settled: Promise.resolve()}), unsaved = () => false, picker, mode = 'untitled', reply = () => ({ok: false}), downloadError} = {}) {
  const calls = [], downloads = [], input = {addEventListener() {}, removeEventListener() {}}
  const root = {dataset: {generation: '1', editVersion: '0', fileMode: mode, fileName: 'untitled.karton', fileBusy: 'false'}, querySelector: selector => selector === '#canvas-file-input' ? input : null, querySelectorAll: () => [], append() {}}
  globalThis.document = {activeElement: null, createElement: () => ({remove() {}, click() { if (downloadError) throw downloadError; downloads.push({href: this.href, filename: this.download}) }})}
  class Handle { getFile() {} createWritable() {} queryPermission() {} requestPermission() {} }
  globalThis.window = {isSecureContext: true, FileSystemFileHandle: Handle, ...(picker ? {showSaveFilePicker: picker} : {})}
  const workspace = {el: root, flushEdits: flush, hasUnsaved: unsaved, pushEvent(event, payload, callback) { calls.push({event, payload}); callback?.(reply(event, payload)) }}
  return {api: mountNativeFile(workspace), root, calls, downloads}
}

test('New rejects an unsuccessful flush without destructive lifecycle events or a stuck busy state', async () => {
  const {api, calls, root} = fixture({flush: () => ({ok: false})})
  await api.newCanvas()
  assert.deepEqual(calls, [])
  assert.equal(root.dataset.nativeBusy, 'false')
})

test('New waits for draft commit and then rejects the newly dirty document', async () => {
  const commit = deferred(); let dirty = false
  const {api, calls} = fixture({flush: () => ({ok: true, settled: commit.promise}), unsaved: () => dirty})
  const pending = api.newCanvas()
  assert.deepEqual(calls, [])
  dirty = true; commit.resolve(); await pending
  assert.deepEqual(calls.map(call => call.event), ['selected-error'])
})

test('New ignores a flush completion belonging to an old generation and blocks pending persistence', async () => {
  const commit = deferred()
  const {api, calls, root} = fixture({flush: () => ({ok: true, settled: commit.promise})})
  const pending = api.newCanvas(); root.dataset.generation = '2'; commit.resolve(); await pending
  assert.deepEqual(calls, [])
  root.dataset.fileBusy = 'true'; await api.newCanvas()
  assert.deepEqual(calls.map(call => call.event), ['selected-error'])
})

test('first Save invokes picker synchronously and cancellation cannot prepare or promote a source', async () => {
  const pick = deferred(), flush = deferred(), order = []
  const {api, calls} = fixture({picker: () => { order.push('picker'); return pick.promise }, flush: () => { order.push('flush'); return {ok: true, settled: flush.promise} }})
  const saving = api.save()
  assert.deepEqual(order, ['picker', 'flush'])
  pick.resolve(Promise.reject(new DOMException('Canceled', 'AbortError')))
  flush.resolve(); await saving
  assert.deepEqual(calls, [])
})

test('a picker resolving after a generation change cannot serialize or write the new document', async () => {
  const pick = deferred(); let writes = 0
  const {api, calls, root} = fixture({picker: () => pick.promise})
  const saving = api.save(); root.dataset.generation = '2'
  pick.resolve({name: 'stale.json', getFile() {}, createWritable() { writes++ }, queryPermission() {}, requestPermission() {}})
  await saving
  assert.deepEqual(calls, [])
  assert.equal(writes, 0)
})

test('Save a copy refuses an invalid draft without downloading or invoking a native picker', async () => {
  let pickers = 0
  const {api, root, downloads} = fixture({flush: () => ({ok: false}), picker: () => { pickers++ }})
  await api.saveCopy()
  assert.deepEqual(downloads, [])
  assert.equal(pickers, 0)
  assert.equal(root.dataset.nativeBusy, 'false')
})

test('Save a copy waits for pending edits and ignores a superseded document', async () => {
  const commit = deferred()
  const {api, root, calls, downloads} = fixture({mode: 'server_file', flush: () => ({ok: true, settled: commit.promise})})
  const copying = api.saveCopy()
  assert.deepEqual(calls, [])
  root.dataset.generation = '2'
  commit.resolve(); await copying
  assert.deepEqual(downloads, [])
  assert.deepEqual(calls, [])
  assert.equal(root.dataset.nativeBusy, 'false')
})

test('a late copy snapshot cannot download after a document generation changes', async () => {
  let deliver
  const {root, downloads} = fixture({mode: 'browser_file'})
  const workspace = {el: root, flushEdits: () => ({ok: true, settled: Promise.resolve()}), pushEvent(event, payload, callback) {
    if (event === 'save-copy') deliver = callback
    else callback?.({ok: false})
  }}
  const copyingApi = mountNativeFile(workspace)
  const copying = copyingApi.saveCopy()
  await Promise.resolve()
  root.dataset.generation = '2'
  deliver({ok: true, token: 'copy', generation: 1, bytes: '{}', filename: 'copy.json'})
  await copying
  assert.deepEqual(downloads, [])
  assert.equal(root.dataset.nativeBusy, 'false')
  copyingApi.destroyed()
})

test('copy preparation excludes concurrent downloads, saves, and document replacement', async () => {
  const commit = deferred()
  const {api, root, calls, downloads} = fixture({mode: 'server_file', flush: () => ({ok: true, settled: commit.promise})})
  const copying = api.saveCopy()
  await api.saveCopy(); await api.save(); await api.newCanvas()
  assert.deepEqual(downloads, [])
  assert.equal(calls.some(call => ['save', 'save-copy', 'new'].includes(call.event)), false)
  assert.equal(root.dataset.nativeBusy, 'true')
  commit.resolve(); await copying
  assert.equal(root.dataset.nativeBusy, 'false')
})

test('a failed download cannot acknowledge preservation and releases the file-operation guard', async () => {
  const {api, root, calls, downloads} = fixture({mode: 'server_file', downloadError: new Error('Downloads blocked'), reply: event =>
    event === 'save-copy' ? {ok: true, token: 'copy', generation: 1, bytes: '{}', filename: 'copy.json'} : {ok: false}})
  await api.saveCopy()
  assert.deepEqual(downloads, [])
  assert.equal(calls.some(call => call.event === 'selected-copy-downloaded'), false)
  assert.equal(calls.find(call => call.event === 'selected-save-error').payload.token, 'copy')
  assert.equal(root.dataset.nativeBusy, 'false')
})

test('an unsuccessful asynchronous thought commit cannot download a stale graph', async () => {
  const {api, root, calls, downloads} = fixture({mode: 'server_file', flush: () => ({ok: true, settled: Promise.reject(new Error('Thought was not added'))})})
  await api.saveCopy()
  assert.deepEqual(downloads, [])
  assert.equal(calls.some(call => call.event === 'save-copy'), false)
  assert.equal(root.dataset.nativeBusy, 'false')
})

test('separate v2 copy waits for edits, downloads the new name, and never promotes the source', async () => {
  const commit = deferred()
  const {api, root, calls, downloads} = fixture({mode: 'browser_file', flush: () => ({ok: true, settled: commit.promise}), reply: event =>
    event === 'version-copy' ? {ok: true, token: 'v2', generation: 1, bytes: '{"version":2}', filename: 'untitled-v2.json'} : {ok: true}})
  const copying = api.convertVersionCopy()
  assert.deepEqual(calls, [])
  commit.resolve(); await copying
  assert.equal(downloads.length, 1)
  assert.equal(downloads[0].filename, 'untitled-v2.json')
  assert.deepEqual(calls.map(call => call.event), ['version-copy', 'selected-version-copy-downloaded'])
  assert.equal(root.dataset.fileMode, 'browser_file')
  assert.equal(root.dataset.fileName, 'untitled.karton')
  assert.equal(root.dataset.generation, '1')
})

test('failed conversion download reports its token without any save or conversion acknowledgment', async () => {
  const {api, root, calls, downloads} = fixture({mode: 'server_file', downloadError: new Error('Blocked'), reply: event =>
    event === 'version-copy' ? {ok: true, token: 'v2', generation: 1, bytes: '{}', filename: 'separate-v2.json'} : {ok: true}})
  await api.convertVersionCopy()
  assert.deepEqual(downloads, [])
  assert.deepEqual(calls.map(call => call.event), ['version-copy', 'selected-save-error'])
  assert.equal(calls[1].payload.token, 'v2')
  assert.equal(root.dataset.fileMode, 'server_file')
  assert.equal(root.dataset.nativeBusy, 'false')
})

test('conversion cannot download an invalid draft or a superseded generation', async () => {
  const invalid = fixture({flush: () => ({ok: false})})
  await invalid.api.convertVersionCopy()
  assert.deepEqual(invalid.calls, [])
  const commit = deferred()
  const stale = fixture({flush: () => ({ok: true, settled: commit.promise})})
  const pending = stale.api.convertVersionCopy()
  stale.root.dataset.generation = '2'; commit.resolve(); await pending
  assert.deepEqual(stale.calls, [])
  assert.deepEqual(stale.downloads, [])
})
