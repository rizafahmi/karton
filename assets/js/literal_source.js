export const normalizeView = source => source.replace(/\r\n|\r/g, '\n')
export const sourceBytes = source => new TextEncoder().encode(source).length
export function validateSource(source, limit = 262144) {
  if (typeof source !== 'string') return 'Code source must be text.'
  for (let i = 0; i < source.length; i++) {
    const c = source.charCodeAt(i)
    if (c >= 0xd800 && c <= 0xdbff) {
      const next = source.charCodeAt(++i)
      if (!(next >= 0xdc00 && next <= 0xdfff)) return 'Code contains an unpaired Unicode surrogate.'
    } else if (c >= 0xdc00 && c <= 0xdfff) return 'Code contains an unpaired Unicode surrogate.'
    else if (c < 32 && ![9, 10, 13].includes(c) || c >= 127 && c <= 159) return 'Code contains an unsupported control character.'
  }
  return sourceBytes(source) > limit ? `Code exceeds the ${limit.toLocaleString()} UTF-8 byte limit.` : null
}

// Textarea indices are UTF-16, but CRLF occupies only one textarea position.
export function literalOffset(source, index) {
  let view = 0, offset = 0
  while (offset < source.length && view < index) {
    offset += source[offset] === '\r' && source[offset + 1] === '\n' ? 2 : 1
    view++
  }
  return offset
}
export function enterTerminator(source, index) {
  const offset = literalOffset(source, index)
  const endings = [...source.matchAll(/\r\n|\r|\n/g)]
  return endings.find(match => match.index >= offset)?.[0] || endings.at(-1)?.[0] || '\n'
}
export class LiteralSource {
  constructor(source = '') { this.source = source; this.past = []; this.future = [] }
  get view() { return normalizeView(this.source) }
  replace(start, end, inserted, selection = [start, end]) {
    const before = this.source
    const next = before.slice(0, literalOffset(before, start)) + inserted + before.slice(literalOffset(before, end))
    if (before !== next) {
      this.past.push({source: before, selection}); this.future = []; this.source = next
    }
    const caret = start + normalizeView(inserted).length
    return [caret, caret]
  }
  reconcile(view, selection) {
    const before = this.view
    if (view === before) return selection
    let start = 0, end = before.length, nextEnd = view.length
    while (start < end && start < nextEnd && before[start] === view[start]) start++
    while (end > start && nextEnd > start && before[end - 1] === view[nextEnd - 1]) { end--; nextEnd-- }
    this.replace(start, end, view.slice(start, nextEnd), selection)
    return selection
  }
  history(redo, selection) {
    const from = redo ? this.future : this.past, to = redo ? this.past : this.future
    const state = from.pop()
    if (!state) return selection
    to.push({source: this.source, selection}); this.source = state.source
    return state.selection
  }
  indent(start, end, outdent = false) {
    const view = this.view, first = view.lastIndexOf('\n', start - 1) + 1
    if (!outdent && start === end) return this.replace(start, end, '  ')
    const last = end > start && view[end - 1] === '\n' ? end - 1 : end
    const edits = []
    for (let pos = first; pos <= last;) {
      const remove = outdent ? view[pos] === '\t' ? 1 : /^ {1,2}/.exec(view.slice(pos))?.[0].length || 0 : 0
      edits.push({pos, remove, text: outdent ? '' : '  '})
      const next = view.indexOf('\n', pos)
      if (next < 0) break
      pos = next + 1
    }
    const before = this.source
    let source = before
    for (const edit of edits.toReversed()) source = source.slice(0, literalOffset(before, edit.pos)) + edit.text + source.slice(literalOffset(before, edit.pos + edit.remove))
    if (source !== before) { this.past.push({source: before, selection: [start, end]}); this.future = []; this.source = source }
    const map = index => index + edits.reduce((n, e) => n + (e.pos <= index ? e.text.length - Math.min(e.remove, index - e.pos) : 0), 0)
    return [map(start), map(end)]
  }
}
