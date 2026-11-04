import {createHighlighterCore} from '@shikijs/core'
import {createJavaScriptRegexEngine} from '@shikijs/engine-javascript'
import githubLight from '@shikijs/themes/github-light'
import githubDark from '@shikijs/themes/github-dark'
import elixir from '@shikijs/langs/elixir'
import erlang from '@shikijs/langs/erlang'
import javascript from '@shikijs/langs/javascript'
import typescript from '@shikijs/langs/typescript'
import json from '@shikijs/langs/json'
import html from '@shikijs/langs/html'
import css from '@shikijs/langs/css'
import shell from '@shikijs/langs/shellscript'
import python from '@shikijs/langs/python'
import sql from '@shikijs/langs/sql'
import swift from '@shikijs/langs/swift'
import rust from '@shikijs/langs/rust'
import hljs from 'highlight.js/lib/core'
import detectElixir from 'highlight.js/lib/languages/elixir'
import detectErlang from 'highlight.js/lib/languages/erlang'
import detectJavascript from 'highlight.js/lib/languages/javascript'
import detectTypescript from 'highlight.js/lib/languages/typescript'
import detectJson from 'highlight.js/lib/languages/json'
import detectHtml from 'highlight.js/lib/languages/xml'
import detectCss from 'highlight.js/lib/languages/css'
import detectShell from 'highlight.js/lib/languages/bash'
import detectPython from 'highlight.js/lib/languages/python'
import detectSql from 'highlight.js/lib/languages/sql'
import detectSwift from 'highlight.js/lib/languages/swift'
import detectRust from 'highlight.js/lib/languages/rust'

export const languages = ['plaintext', 'elixir', 'erlang', 'javascript', 'typescript', 'json', 'html', 'css', 'shell', 'python', 'sql', 'swift', 'rust']
const detectorNames = {html: 'xml', shell: 'bash'}
const detectors = [detectElixir, detectErlang, detectJavascript, detectTypescript, detectJson, detectHtml, detectCss, detectShell, detectPython, detectSql, detectSwift, detectRust]
for (const [index, name] of languages.slice(1).entries()) hljs.registerLanguage(detectorNames[name] || name, detectors[index])
const canonical = name => Object.keys(detectorNames).find(key => detectorNames[key] === name) || name
export function detectLanguage(source) {
  if (!source.trim()) return null
  const result = hljs.highlightAuto(source, languages.slice(1).map(name => detectorNames[name] || name))
  if (!result.language || result.relevance < 3 || result.secondBest && result.relevance < result.secondBest.relevance * 1.25) return null
  return canonical(result.language)
}
let highlighter
export async function highlightSource(source, choice, theme = 'github-light') {
  const effective = choice === 'auto' ? detectLanguage(source) : languages.includes(choice) ? choice : null
  if (!effective || effective === 'plaintext') return {effective: effective || 'plaintext', status: choice === 'auto' ? 'Auto: uncertain; plain text' : effective ? 'Plain text' : `Unsupported language: ${choice}; plain text`, tokens: [{text: source}]}
  highlighter ||= createHighlighterCore({themes: [githubLight, githubDark], langs: [elixir, erlang, javascript, typescript, json, html, css, shell, python, sql, swift, rust], engine: createJavaScriptRegexEngine()})
  const engine = await highlighter
  // Shiki tokenizes lines; reconstruct their exact original separators, not a
  // newline-normalized token serialization. Tokens are never canonical source.
  const lines = source.split(/\r\n|\r|\n/), endings = source.match(/\r\n|\r|\n/g) || []
  const result = engine.codeToTokens(source.replace(/\r\n|\r/g, '\n'), {lang: effective === 'shell' ? 'shellscript' : effective, theme: theme === 'github-dark' ? 'github-dark' : 'github-light'})
  const tokens = []
  for (let i = 0; i < lines.length; i++) {
    const lineTokens = result.tokens[i] || []
    if (lineTokens.map(token => token.content).join('') !== lines[i]) throw new Error('Highlighter changed source text')
    for (const token of lineTokens) tokens.push({text: token.content, color: token.color})
    if (endings[i]) tokens.push({text: endings[i]})
  }
  return {effective, status: choice === 'auto' ? `Auto: ${effective}` : effective, tokens}
}
