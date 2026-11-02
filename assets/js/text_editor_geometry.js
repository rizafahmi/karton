// Preview the text box in the same geometry used by native guides and edges.
// Leave persistence, text changes and history to Hakushi's editText lifecycle.
export function mountTextEditorGeometry(canvas, node, editor) {
  if (node.el.querySelector("[data-hakushi-text]")?.hasAttribute("data-hakushi-text-own")) return

  const baseHeight = node.height
  const baseStyleHeight = node.el.style.height
  let finished = false
  const refresh = () => {
    // Hakushi rereads nodes after text visibility/server DOM mutations.
    const live = canvas.nodes.get(node.id)
    canvas.measureHandles(live?.el === node.el ? live : node)
    canvas.touchNode(node.id)
    canvas.schedule()
  }
  const preview = () => {
    if (finished) return
    const height = Math.max(baseHeight, Math.ceil(editor.scrollHeight))
    if (node.el.drawingTextHeight === height) return
    node.el.drawingTextHeight = height
    node.el.style.height = `${height}px`
    refresh()
  }
  const restore = () => {
    if (finished) return
    finished = true
    delete node.el.drawingTextHeight
    const live = canvas.nodes.get(node.id)
    if (live?.el === node.el) live.height = baseHeight
    node.height = baseHeight
    node.el.style.height = baseStyleHeight
    refresh()
    editor.removeEventListener("input", preview)
    editor.removeEventListener("keydown", finishKey, true)
    editor.removeEventListener("blur", restore, true)
  }
  const finishKey = event => {
    if (event.isComposing || event.keyCode === 229) return
    if (event.key === "Escape" || event.key === "Enter" && (event.metaKey || event.ctrlKey)) restore()
  }
  editor.addEventListener("input", preview)
  // Restore before native finish: its reply compares scrollHeight with node.height
  // to decide whether to persist a resize. Escape must leave no preview behind.
  editor.addEventListener("keydown", finishKey, true)
  editor.addEventListener("blur", restore, true)
  preview()
}
