import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import test from 'node:test'
const source = await readFile(new URL('../assets/js/literal_source.js', import.meta.url), 'utf8')
const {LiteralSource, enterTerminator, literalOffset, sourceBytes, validateSource} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

test('no-op textarea round trip preserves BOM, mixed endings, tabs and Unicode', () => {
  const original = '\ufeff\tα  \r\nβ\r😀e\u0301\nlast\t '
  const model = new LiteralSource(original)
  model.reconcile(model.view, [0, 0])
  assert.equal(model.source, original)
  assert.equal(model.past.length, 0)
  assert.equal(literalOffset(original, model.view.indexOf('β')), original.indexOf('β'))
})
test('selected replacement and literal paste preserve every untouched source segment', () => {
  const model = new LiteralSource('\ufeffa\r\nb\rc\nd')
  model.replace(3, 4, 'x\r\ny\rz\n\t😀')
  assert.equal(model.source, '\ufeffa\r\nx\r\ny\rz\n\t😀\rc\nd')
  model.reconcile(model.view.replace('😀', '😺'), [15, 15])
  assert.equal(model.source, '\ufeffa\r\nx\r\ny\rz\n\t😺\rc\nd')
})
test('Enter uses current line then preceding then first ending then LF', () => {
  const source = 'a\r\nb\rc\nlast'
  assert.equal(enterTerminator(source, 0), '\r\n')
  assert.equal(enterTerminator(source, 2), '\r')
  assert.equal(enterTerminator(source, 4), '\n')
  assert.equal(enterTerminator(source, 10), '\n')
  assert.equal(enterTerminator('last', 2), '\n')
})
test('multi-line indentation respects selection end at line boundary and undoes atomically', () => {
  const model = new LiteralSource('a\r\nb\rc\n')
  const selected = model.indent(0, 4)
  assert.equal(model.source, '  a\r\n  b\rc\n')
  assert.deepEqual(selected, [2, 8])
  assert.deepEqual(model.history(false, selected), [0, 4])
  assert.equal(model.source, 'a\r\nb\rc\n')
  model.history(true, [0, 4]); model.indent(2, 8, true)
  assert.equal(model.source, 'a\r\nb\rc\n')
})
test('outdent removes at most two spaces or one tab and retains mixed endings', () => {
  const model = new LiteralSource('\ta\r\n   b\rc')
  model.indent(0, model.view.length, true)
  assert.equal(model.source, 'a\r\n b\rc')
})
test('UTF-8 quotas are inclusive and reject lone surrogates and forbidden controls', () => {
  assert.equal(validateSource('😀'.repeat(65536)), null)
  assert.match(validateSource('😀'.repeat(65536) + 'a'), /byte limit/)
  assert.equal(sourceBytes('\ufeff\r\n\t'), 6)
  for (const invalid of ['\ud800', '\udc00', 'x\ud800y', '\0', '\u007f', '\u0085']) assert.ok(validateSource(invalid))
  assert.equal(validateSource('\ufeff\t\r\n😀'), null)
})
