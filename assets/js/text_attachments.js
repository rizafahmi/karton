const textExtensions = new Set([
  "md", "markdown", "mdown", "mkd", "txt", "text", "json", "jsonl", "ndjson", "csv", "tsv", "log",
  "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss", "sass", "less", "js", "mjs", "cjs", "jsx",
  "ts", "tsx", "ex", "exs", "erl", "hrl", "sh", "bash", "zsh", "fish", "py", "rb", "php", "lua", "pl",
  "c", "h", "cc", "hh", "cpp", "hpp", "rs", "go", "java", "kt", "kts", "swift", "sql", "r", "rmd",
  "ini", "conf", "cfg", "env", "properties", "svg", "rst", "adoc", "asciidoc", "tex", "org", "ps1",
  "bat", "cmd", "gitignore", "gitattributes",
])
const markdownExtensions = new Set(["md", "markdown", "mdown", "mkd"])
const binaryControls = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]/u
const loneSurrogates = /[\uD800-\uDFFF]/u
const encoder = new TextEncoder()

function safeFilename(filename) {
  if (typeof filename !== "string" || !filename.trim() || filename === "." || filename === ".." ||
      /[\\/\p{Cc}]/u.test(filename) || loneSurrogates.test(filename) || encoder.encode(filename).byteLength > 255) {
    throw new Error("The filename must be a safe basename of at most 255 UTF-8 bytes, without paths or control characters.")
  }
  return filename
}

function checkText(content) {
  if (loneSurrogates.test(content) || binaryControls.test(content)) {
    throw new Error("Only UTF-8 text is supported; binary control characters are not allowed (except tab and line endings).")
  }
}

function visibleCenterBox(canvas, workspace) {
  const bounds = canvas.root.getBoundingClientRect()
  const rail = canvas.controlsEl?.getBoundingClientRect()
  const header = workspace.querySelector(".canvas-header")?.getBoundingClientRect()
  const dock = canvas.toolsEl?.getBoundingClientRect()
  const left = rail ? Math.max(24, rail.right - bounds.left + 12) : 24
  const right = Math.max(left, canvas.size.width - 24)
  const top = header ? Math.max(24, header.bottom - bounds.top + 12) : 24
  const bottom = Math.max(top, dock ? Math.min(canvas.size.height - 24, dock.top - bounds.top - 24) : canvas.size.height - 24)
  return [((left + right) / 2 - canvas.view.x) / canvas.view.zoom - 120,
    ((top + bottom) / 2 - canvas.view.y) / canvas.view.zoom - 56, 240, 112]
}

const hasFiles = transfer => transfer && (
  Array.from(transfer.types || []).includes("Files") || transfer.files?.length > 0 ||
  Array.from(transfer.items || []).some(item => item.kind === "file")
)
const stopFileEvent = event => {
  event.preventDefault()
  event.stopImmediatePropagation()
}

export function mountTextAttachments(workspace) {
  const root = workspace.el
  const generation = () => Number(root.dataset.generation)
  const activeElement = () => workspace.activeCanvas()
  const activeCanvas = () => activeElement()?.fileCanvas
  const inputAccept = `text/*,${[...textExtensions].map(extension => `.${extension}`).join(",")}`
  const status = document.createElement("p")
  status.id = "attachment-import-status"
  status.setAttribute("role", "status")
  status.setAttribute("aria-atomic", "true")
  const statusText = document.createElement("span")
  const dismiss = document.createElement("button")
  dismiss.type = "button"
  dismiss.className = "attachment-import-dismiss"
  dismiss.textContent = "Dismiss"
  dismiss.setAttribute("aria-label", "Dismiss attachment message")
  status.append(statusText, dismiss)
  let input = null
  let operation = null
  let preview = null
  let pendingFocus = null
  let alive = true
  let currentGeneration = generation()
  let statusMessage = ""
  let statusState = ""

  const isCurrent = request => alive && !request.cancelled && request.generation === generation() &&
    request.canvasElement === activeElement() && request.canvas === activeCanvas()
  const limits = () => {
    const file = Number(root.dataset.attachmentFileLimit)
    const total = Number(root.dataset.attachmentTotalLimit)
    if (!Number.isSafeInteger(file) || file <= 0 || !Number.isSafeInteger(total) || total <= 0) {
      throw new Error("Attachment limits are unavailable. Reload this page before attaching a file.")
    }
    return {file, total}
  }
  const checkSize = (bytes, maximum) => {
    if (!Number.isSafeInteger(bytes) || bytes < 0 || bytes > maximum.file) {
      throw new Error(`The file exceeds the ${maximum.file.toLocaleString()}-byte attachment limit. No file was attached.`)
    }
    // Existing attachments and duplicates are counted by the server, not DOM metadata.
    if (bytes > maximum.total) {
      throw new Error(`Attachments may total at most ${maximum.total.toLocaleString()} bytes per canvas. No file was attached.`)
    }
  }
  const setStatus = (message, state = "", request = null) => {
    if (!alive || request && !isCurrent(request)) return
    statusMessage = message
    statusState = state
    if (statusText.textContent !== message) statusText.textContent = message
    status.dataset.state = state
    status.hidden = !message
  }
  const onDismiss = () => {
    setStatus("")
    const button = root.querySelector("#attach-text-file")
    const target = button && !button.disabled ? button : activeCanvas()?.root
    target?.focus({preventScroll: true})
  }
  dismiss.addEventListener("click", onDismiss)
  const canEdit = () => {
    const element = activeElement(), canvas = activeCanvas()
    return element?.fileCanvasReady === true && !!canvas && !canvas.config.readonly && root.dataset.fileMode !== "none"
  }
  const syncControls = () => {
    if (!alive) return
    root.dataset.attachmentBusy = String(!!operation)
    if (!root.contains(status)) root.append(status)
    if (statusText.textContent !== statusMessage) statusText.textContent = statusMessage
    status.dataset.state = statusState
    status.hidden = !statusMessage
    const disabled = !!operation || root.dataset.nativeBusy === "true" || root.dataset.fileBusy === "true" || !canEdit() || !input
    const button = root.querySelector("#attach-text-file")
    if (button) {
      button.disabled = disabled
      const describedBy = new Set((button.getAttribute("aria-describedby") || "").split(/\s+/).filter(Boolean))
      if (statusMessage) describedBy.add(status.id)
      else describedBy.delete(status.id)
      button.setAttribute("aria-describedby", [...describedBy].join(" "))
    }
  }
  const finish = (request, result = true, refocus = false) => {
    if (operation !== request) return
    const current = isCurrent(request)
    operation = null
    request.cancelled = true
    request.resolve(result)
    if (refocus && current && request.trigger?.isConnected) request.trigger.focus({preventScroll: true})
    root.dataset.attachmentBusy = "false"
    syncControls()
    if (alive) root.dispatchEvent(new CustomEvent("canvas:settled", {bubbles: true}))
  }
  const focusPending = () => {
    const request = pendingFocus
    if (!request) return
    if (!isCurrent(request)) { pendingFocus = null; return }
    const node = request.canvas.nodes.get(request.node)
    if (!node || !node.el.isConnected || request.canvas.gone.has(node.id)) return
    pendingFocus = null
    if (document.activeElement !== document.body && document.activeElement !== request.canvas.root &&
        document.activeElement !== request.trigger) return
    request.canvas.selectPending()
    request.canvas.culled.delete(node.id)
    node.el.removeAttribute("data-ui-culled")
    request.canvas.lastFocus = node.el
    request.canvas.revealNodes([node.id])
    node.el.focus({preventScroll: true})
    request.canvas.schedule()
  }

  const begin = (phase, event = null) => {
    if (operation || root.dataset.nativeBusy === "true" || root.dataset.fileBusy === "true") {
      setStatus("Wait for the current file operation to finish before attaching another file.", "error")
      return null
    }
    if (!canEdit()) {
      setStatus(root.dataset.fileMode === "none"
        ? "Open or create a canvas before attaching a text file."
        : "Wait for an editable canvas to finish loading before attaching a text file.", "error")
      return null
    }
    const canvas = activeCanvas()
    if (canvas.gesture) {
      setStatus("Finish the current canvas gesture before attaching a text file.", "error")
      return null
    }
    const request = {generation: generation(), canvasElement: activeElement(), canvas, phase, trigger: document.activeElement}
    const chrome = event?.target.closest(".canvas-header, .hakushi-controls, .hakushi-tools, .hakushi-style-panel, .hakushi-minimap, #file-menu, [data-hakushi-people], .hakushi-following")
    const point = event && canvas.root.contains(event.target) && !chrome ? canvas.canvasPoint(event) : null
    request.box = point ? [point.x, point.y, 240, 112] : visibleCenterBox(canvas, root)
    let flushed
    try {
      limits()
      // Flush before owning a waiter, so an import never waits on itself.
      flushed = workspace.flushEdits()
    } catch (error) {
      setStatus(error.message, "error", request)
      return null
    }
    if (!flushed.ok) {
      setStatus("Finish or cancel the current canvas edit before attaching a text file.", "error", request)
      return null
    }
    // Observe a failed native edit immediately, even if the picker is later cancelled.
    request.editsSettled = flushed.settled.then(() => null, error => error)
    request.settled = new Promise(resolve => { request.resolve = resolve })
    operation = request
    pendingFocus = null
    setStatus("", "", request)
    syncControls()
    return request
  }

  const importFiles = async (request, files) => {
    if (!request) return
    let success = true
    try {
      if (!isCurrent(request)) return
      if (!files.length) return
      if (files.length !== 1) throw new Error("Choose exactly one text file. No files were attached.")
      const file = files[0]
      const filename = safeFilename(file.name)
      const extension = filename.split(".").pop().toLowerCase()
      const mediaType = typeof file.type === "string" ? file.type.toLowerCase().split(";", 1)[0].trim() : ""
      if (!mediaType.startsWith("text/") && !textExtensions.has(extension)) {
        throw new Error("Choose a text file such as Markdown, TXT, JSON, CSV, or source code. No file was attached.")
      }
      const maximum = limits()
      checkSize(file.size, maximum)
      request.phase = "reading"
      if (!isCurrent(request)) return
      const buffer = await file.arrayBuffer()
      if (!isCurrent(request)) return
      checkSize(buffer.byteLength, maximum)
      let content
      try {
        // Unlike File.text(), this refuses malformed UTF-8 and preserves its BOM.
        content = new TextDecoder("utf-8", {fatal: true, ignoreBOM: true}).decode(buffer)
      } catch {
        throw new Error("The file is not valid UTF-8. Convert it to UTF-8 and try again; no file was attached.")
      }
      checkText(content)
      const editError = await request.editsSettled
      if (!isCurrent(request)) return
      if (editError) throw new Error(`The current canvas edit could not finish: ${editError.message}`)
      if (!canEdit() || root.dataset.fileBusy === "true" || request.canvas.gesture) {
        throw new Error("The canvas is not ready to accept this attachment. No file was attached.")
      }
      // A save/new operation may now be waiting on this import's flush waiter.
      // Its nativeBusy flag must not prevent an import that started before it.
      const attachment = {filename, media_type: mediaType === "text/markdown" || markdownExtensions.has(extension) ? "text/markdown" : "text/plain",
        encoding: "utf-8", content}
      request.phase = "posting"
      const reply = await new Promise(resolve => request.canvas.push("hakushi:draw", {
        tool: "drawing:attachment", generation: request.generation, box: request.box, attachment,
      }, resolve))
      if (!isCurrent(request)) return
      if (reply?.ok !== true || typeof reply.drawn !== "string" || !reply.drawn || reply.error) {
        throw new Error(reply?.error || "The text file was not attached. No file was added.")
      }
      request.canvas.setTool(null)
      request.canvas.pendingSelect = [reply.drawn]
      request.canvas.selectPending()
      // A streamed node may arrive after the reply; retain only its id for focus.
      pendingFocus = {generation: request.generation, canvasElement: request.canvasElement, canvas: request.canvas,
        node: reply.drawn, trigger: request.trigger}
      focusPending()
      setStatus(`Attached ${filename}. Double-click the card or press Enter to preview its literal text.`, "success", request)
    } catch (error) {
      success = false
      setStatus(error.message || "The text file could not be attached. No file was added.", "error", request)
    } finally {
      finish(request, success, !files.length)
    }
  }
  const onInputChange = event => {
    const request = operation?.phase === "picker" ? operation : null
    const files = Array.from(event.target.files || [])
    event.target.value = ""
    return importFiles(request, files)
  }
  const onInputCancel = () => {
    const request = operation?.phase === "picker" ? operation : null
    if (input) input.value = ""
    if (request) { setStatus("", "", request); finish(request, true, true) }
  }
  const bindInput = () => {
    const next = root.querySelector("#attachment-file-input")
    if (next === input) return
    input?.removeEventListener("change", onInputChange)
    input?.removeEventListener("cancel", onInputCancel)
    if (operation?.phase === "picker") finish(operation)
    input = next
    if (input) {
      input.multiple = false
      input.accept = inputAccept
      input.addEventListener("change", onInputChange)
      input.addEventListener("cancel", onInputCancel)
    }
  }
  const onAttach = event => {
    event.preventDefault()
    if (!input) { setStatus("The text file picker is unavailable. Reload this page and try again.", "error"); return }
    const request = begin("picker")
    if (!request) return
    input.value = ""
    try {
      // Keep the file picker inside the original user activation.
      input.click()
    } catch (error) {
      setStatus(`Could not choose a text file: ${error.message}`, "error", request)
      finish(request, false, true)
    }
  }
  const onDragOver = event => {
    if (!hasFiles(event.dataTransfer)) return
    stopFileEvent(event)
    event.dataTransfer.dropEffect = operation || root.dataset.nativeBusy === "true" || root.dataset.fileBusy === "true" || !canEdit() ? "none" : "copy"
  }
  const onDrop = event => {
    if (!hasFiles(event.dataTransfer)) return
    stopFileEvent(event)
    activeCanvas()?.root.removeAttribute("data-ui-dropping")
    const files = Array.from(event.dataTransfer.files || [])
    if (files.length !== 1) { setStatus("Choose exactly one text file. No files were attached.", "error"); return }
    return importFiles(begin("reading", event), files)
  }
  const onFlush = event => {
    if (!operation) return
    if (!event.detail?.waiters) {
      event.preventDefault()
      setStatus("Wait for the text attachment import to finish before opening another canvas.", "error")
      return
    }
    event.detail.waiters.push(operation.settled.then(ok => {
      if (!ok) throw new Error("The text file was not attached. No attachment was added; choose it again before saving.")
      return true
    }))
  }

  const closePreview = () => {
    const current = preview
    if (!current) return
    preview = null
    current.cancelled = true
    current.dialog.removeEventListener("close", current.onClose)
    current.download.removeEventListener("click", current.onDownload)
    if (current.dialog.open) current.dialog.close()
    current.dialog.returnValue = ""
    current.dialog.remove()
  }
  const attachmentNode = (canvas, target) => {
    const element = target?.closest(".hakushi-node[data-id]")
    const node = element && canvas.nodes.get(element.dataset.id)
    return node && node.el === element && element.isConnected && !canvas.gone.has(node.id) &&
      element.querySelector(".drawing-typography[data-attachment]") ? node : null
  }
  const showPreview = async node => {
    const canvas = activeCanvas()
    const canvasElement = activeElement()
    if (!canvas || !canvasElement?.fileCanvasReady) return
    closePreview()
    const dialog = document.createElement("dialog")
    dialog.id = `${root.id}-attachment-preview`
    dialog.className = "attachment-preview"
    const title = document.createElement("h2")
    title.id = `${dialog.id}-title`
    title.className = "attachment-preview-title"
    title.textContent = node.label || "Text attachment"
    dialog.setAttribute("aria-labelledby", title.id)
    const meta = document.createElement("p")
    meta.className = "attachment-preview-meta"
    meta.textContent = "Literal source · UTF-8"
    const content = document.createElement("pre")
    content.className = "attachment-preview-content"
    content.tabIndex = 0
    content.setAttribute("role", "region")
    content.setAttribute("aria-label", "Attachment source")
    const message = document.createElement("p")
    message.className = "attachment-preview-status"
    message.setAttribute("role", "status")
    message.textContent = "Reading attachment…"
    const actions = document.createElement("div")
    actions.className = "attachment-preview-actions"
    const download = document.createElement("button")
    download.type = "button"
    download.className = "attachment-preview-download"
    download.textContent = "Download attachment"
    download.disabled = true
    const form = document.createElement("form")
    form.method = "dialog"
    const close = document.createElement("button")
    close.type = "submit"
    close.className = "attachment-preview-close"
    close.value = "close"
    close.autofocus = true
    close.textContent = "Close"
    form.append(close)
    actions.append(download, form)
    dialog.append(title, meta, content, message, actions)
    const request = {generation: generation(), canvasElement, canvas, node: node.id, dialog, download, attachment: null}
    preview = request
    request.onClose = () => { if (preview === request) closePreview() }
    request.onDownload = () => {
      if (preview !== request || !isCurrent(request) || !request.attachment) return
      let url, link
      try {
        url = URL.createObjectURL(new Blob([request.attachment.content], {type: "text/plain"}))
        link = document.createElement("a")
        link.hidden = true
        link.href = url
        link.download = request.attachment.filename
        document.body.append(link)
        link.click()
        message.textContent = "Download started. Check your browser’s downloads; saving to disk cannot be confirmed."
      } catch (error) {
        message.textContent = `Could not start download: ${error.message}`
      } finally {
        link?.remove()
        if (url) setTimeout(() => URL.revokeObjectURL(url), 0)
      }
    }
    dialog.addEventListener("close", request.onClose)
    download.addEventListener("click", request.onDownload)
    document.body.append(dialog)
    try {
      canvas.culled.delete(node.id)
      node.el.removeAttribute("data-ui-culled")
      canvas.lastFocus = node.el
      canvas.revealNodes([node.id])
      node.el.focus({preventScroll: true})
      dialog.showModal()
      const reply = await new Promise(resolve => canvas.push("drawing:attachment-read", {
        generation: request.generation, node: node.id,
      }, resolve))
      if (preview !== request || !isCurrent(request)) return
      if (reply?.ok !== true || reply.error) throw new Error(reply?.error || "The attachment could not be read.")
      const attachment = reply.attachment
      if (!attachment || !["text/plain", "text/markdown"].includes(attachment.media_type) || attachment.encoding !== "utf-8" ||
          typeof attachment.content !== "string") throw new Error("The attachment metadata is not supported.")
      safeFilename(attachment.filename)
      checkText(attachment.content)
      const bytes = encoder.encode(attachment.content).byteLength
      checkSize(bytes, limits())
      request.attachment = attachment
      title.textContent = attachment.filename
      meta.textContent = `${attachment.media_type} · UTF-8 · ${bytes.toLocaleString()} bytes · Literal source, not rendered markup`
      content.textContent = attachment.content
      message.textContent = bytes === 0 ? "This attachment is empty." : ""
      download.disabled = false
    } catch (error) {
      if (preview === request && isCurrent(request)) {
        if (!dialog.open) { closePreview(); setStatus(`Could not open attachment preview: ${error.message}`, "error"); return }
        message.textContent = error.message || "The attachment could not be read."
      }
    }
  }
  const onDoubleClick = event => {
    const canvas = activeCanvas()
    if (!canvas || canvas.tool || canvas.gesture || activeElement()?.directKeyboard?.active) return
    // Native pointer capture can retarget the double-click to the canvas root.
    const target = document.elementFromPoint(event.clientX, event.clientY) || event.target
    if (target.closest("input, textarea, select, button, a[href], [contenteditable]:not([contenteditable=false])")) return
    const node = attachmentNode(canvas, target)
    if (!node) return
    event.preventDefault()
    event.stopImmediatePropagation()
    return showPreview(node)
  }
  const onKeyDown = event => {
    const canvas = activeCanvas()
    if (!canvas || event.defaultPrevented || event.isComposing || event.keyCode === 229 || event.repeat ||
        event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || !["Enter", "F2"].includes(event.key) ||
        canvas.tool || canvas.gesture || activeElement()?.directKeyboard?.active) return
    let node = event.target.classList.contains("hakushi-node") ? attachmentNode(canvas, event.target) : null
    if (event.target === canvas.root && canvas.selected.size === 1 && canvas.selectedEdges.size === 0) {
      node = attachmentNode(canvas, canvas.nodes.get([...canvas.selected][0])?.el)
    }
    if (!node) return
    event.preventDefault()
    event.stopImmediatePropagation()
    return showPreview(node)
  }
  const updated = () => {
    if (!alive) return
    if (currentGeneration !== generation()) {
      currentGeneration = generation()
      if (operation) finish(operation)
      pendingFocus = null
      closePreview()
      setStatus("")
    } else {
      if (operation && !isCurrent(operation)) finish(operation)
      if (preview && !isCurrent(preview)) closePreview()
    }
    bindInput()
    syncControls()
    focusPending()
  }
  const observer = new MutationObserver(updated)
  // Readiness is announced separately; streamed nodes may arrive after draw replies.
  observer.observe(root, {childList: true, subtree: true, attributes: true, attributeFilter: ["data-generation", "data-file-busy", "data-native-busy", "tabindex"]})
  root.addEventListener("canvas:attach", onAttach)
  root.addEventListener("canvas:flush", onFlush)
  root.addEventListener("canvas:settled", updated)
  root.addEventListener("dragover", onDragOver, true)
  root.addEventListener("drop", onDrop, true)
  root.addEventListener("dblclick", onDoubleClick, true)
  root.addEventListener("keydown", onKeyDown, true)
  updated()

  return {updated, destroyed() {
    alive = false
    observer.disconnect()
    if (operation) finish(operation)
    pendingFocus = null
    closePreview()
    input?.removeEventListener("change", onInputChange)
    input?.removeEventListener("cancel", onInputCancel)
    root.removeEventListener("canvas:attach", onAttach)
    root.removeEventListener("canvas:flush", onFlush)
    root.removeEventListener("canvas:settled", updated)
    root.removeEventListener("dragover", onDragOver, true)
    root.removeEventListener("drop", onDrop, true)
    root.removeEventListener("dblclick", onDoubleClick, true)
    root.removeEventListener("keydown", onKeyDown, true)
    status.remove()
    dismiss.removeEventListener("click", onDismiss)
  }}
}
