import assert from 'node:assert/strict'
import {readFile} from 'node:fs/promises'
import {createRequire} from 'node:module'
import {pathToFileURL} from 'node:url'
import test from 'node:test'
const require = createRequire(new URL('../assets/package.json', import.meta.url))
let source = await readFile(new URL('../assets/js/code_highlighter.js', import.meta.url), 'utf8')
source = source.replace(/from '([^']+)'/g, (_, name) => `from '${pathToFileURL(require.resolve(name)).href}'`)
const {highlightSource, detectLanguage, languages} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

test('manual plaintext suppresses detection and unsupported authored IDs remain honest plain text', async () => {
  const code = '<script>alert("never execute")</script>\r\n'
  const plain = await highlightSource(code, 'plaintext')
  assert.equal(plain.effective, 'plaintext'); assert.equal(plain.status, 'Plain text')
  assert.deepEqual(plain.tokens, [{text: code}])
  const unknown = await highlightSource(code, 'future-language')
  assert.match(unknown.status, /Unsupported language: future-language/)
  assert.deepEqual(unknown.tokens, [{text: code}])
})
test('Auto does not claim empty, common punctuation or ordinary ambiguous text as a language', async () => {
  for (const code of ['', '  \r\n\t', 'hello world', 'a + b']) {
    assert.equal(detectLanguage(code), null)
    const result = await highlightSource(code, 'auto')
    assert.equal(result.effective, 'plaintext'); assert.match(result.status, /uncertain/)
  }
})
test('manual grammars all return safe records preserving exact mixed endings and BOM', async () => {
  for (const language of languages) {
    const source = '\ufeffconst x = "<img onerror=alert(1)>";\r\n\t// café 😀\rnext\n'
    const result = await highlightSource(source, language)
    assert.equal(result.tokens.map(token => token.text).join(''), source, language)
    assert.equal(result.effective, language)
    assert.ok(result.tokens.every(token => typeof token.text === 'string' && !Object.hasOwn(token, 'html')))
  }
})
test('ink background changes only trusted token colors, never literal text or selected language', async () => {
  const source = 'const count = 123;\r\n'
  const light = await highlightSource(source, 'javascript', 'github-light')
  const dark = await highlightSource(source, 'javascript', 'github-dark')
  assert.equal(light.tokens.map(token => token.text).join(''), source)
  assert.equal(dark.tokens.map(token => token.text).join(''), source)
  assert.notDeepEqual(light.tokens, dark.tokens)
})
