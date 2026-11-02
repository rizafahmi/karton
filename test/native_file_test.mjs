import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'
const source = await readFile(new URL('../assets/js/native_file.js', import.meta.url), 'utf8')
const {mountNativeFile} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
const deferred = () => { let resolve; const promise = new Promise(done => { resolve = done }); return {promise, resolve} }

function fixture({flush = () => ({ok: true, settled: Promise.resolve()}), unsaved = () => false, picker} = {}) {
  const calls = [], input = {addEventListener() {}, removeEventListener() {}}
  const root = {dataset: {generation: '1', editVersion: '0', fileMode: 'untitled', fileName: 'untitled.json', fileBusy: 'false'}, querySelector: selector => selector === '#canvas-file-input' ? input : null, querySelectorAll: () => []}
  globalThis.document = {activeElement: null}
  class Handle { getFile() {} createWritable() {} queryPermission() {} requestPermission() {} }
  globalThis.window = {isSecureContext: true, FileSystemFileHandle: Handle, ...(picker ? {showSaveFilePicker: picker} : {})}
  const workspace = {el: root, flushEdits: flush, hasUnsaved: unsaved, pushEvent(event, payload, callback) { calls.push({event, payload}); callback?.({ok: false}) }}
  return {api: mountNativeFile(workspace), root, calls}
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
