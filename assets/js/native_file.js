const openError = "Save or reload this canvas before opening another file."
const conflictError = "File changed on disk. Reload before saving; your canvas edits are still here."

const supportsWritableHandle = handle => handle &&
  ["getFile", "createWritable", "queryPermission", "requestPermission"]
    .every(method => typeof handle[method] === "function")

async function readSelectedFile(file) {
  // Keep the exact UTF-8 bytes, including a BOM, for Document.decode and its revision.
  // File.text() would silently replace malformed UTF-8 before server validation.
  const buffer = await file.arrayBuffer()
  return new TextDecoder("utf-8", {fatal: true, ignoreBOM: true}).decode(buffer)
}

async function checkRevision(handle, revision) {
  const file = await handle.getFile()
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer())
  const current = Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("")
  if (current !== revision) {
    const error = new Error(conflictError)
    error.fileStatus = "changed"
    throw error
  }
}

function fileError(error, saving = false) {
  if (error.name === "NotAllowedError") {
    return saving
      ? "Permission to save this file was not granted. Your canvas edits are still here."
      : "Permission to read this file was not granted. The current canvas is still here."
  }
  if (error.name === "NotFoundError") return "File is missing or unreadable. Nothing was overwritten."
  return `${saving ? "Could not save file" : "Could not open file"}: ${error.message}`
}

export function mountNativeFile(workspace) {
  const root = workspace.el
  const input = root.querySelector("#canvas-file-input")
  const send = (event, payload) => new Promise(resolve => workspace.pushEvent(event, payload, resolve))
  const generation = () => Number(root.dataset.generation)
  const editVersion = () => Number(root.dataset.editVersion)
  const mode = () => root.dataset.fileMode
  const supportsDirectSave = window.isSecureContext &&
    typeof window.showOpenFilePicker === "function" &&
    supportsWritableHandle(window.FileSystemFileHandle?.prototype)
  const supportsNewSave = window.isSecureContext &&
    typeof window.showSaveFilePicker === "function" &&
    supportsWritableHandle(window.FileSystemFileHandle?.prototype)
  let selectedFile = null
  let pickerRequest = null
  let busy = false
  let alive = true

  const isCurrent = request => alive && request.generation === generation()
  const reportError = (message, request) => {
    if (isCurrent(request)) workspace.pushEvent("selected-error", {generation: request.generation, message})
  }
  const syncButtons = () => {
    const disabled = busy || root.dataset.fileBusy === "true"
    root.dataset.nativeBusy = String(busy)
    for (const help of root.querySelectorAll("[data-native-open-help]")) {
      help.textContent = supportsDirectSave
        ? "Choose a canvas JSON file. With your permission, Save writes back to that file while this tab stays open."
        : "This browser cannot save back to a selected file. Open a canvas JSON file, then Save copy downloads JSON without changing the original."
    }
    for (const button of root.querySelectorAll("#save-file, [data-save-copy], [data-version-copy], #new-canvas, #open-native-file, #empty-open-file, #reload-file, #server-file-options button, #disk-warning .message-action, #rename-document-form input, #rename-document-form button")) {
      button.disabled = disabled || button.id === "save-file" && mode() === "none" || button.matches?.("[data-version-copy]") && root.dataset.documentVersion !== "1"
    }
    const saveButton = root.querySelector("#save-file")
    if (saveButton && root.dataset.sourceMissing === "true") {
      const filename = root.dataset.fileName || "untitled.json"
      const canChooseFile = mode() === "untitled" && supportsNewSave
      saveButton.querySelector("span").textContent = canChooseFile ? "Save" : "Save copy"
      saveButton.title = canChooseFile
        ? `Choose a file to save ${filename}`
        : `Download ${filename}; saving to disk cannot be confirmed`
    }
  }
  const setBusy = value => {
    busy = value
    syncButtons()
  }
  const finishPicker = request => {
    setBusy(false)
    if (request?.trigger?.isConnected) request.trigger.focus()
  }

  const acceptFile = async (request, file, handle) => {
    const bytes = await readSelectedFile(file)
    await request.settled
    const flushed = workspace.flushEdits()
    if (!flushed.ok) return
    await flushed.settled
    if (!isCurrent(request)) return
    const reloading = request.action === "reload" && (file.name === request.filename || root.dataset.sourceMissing === "true")
    if (!reloading && workspace.hasUnsaved()) {
      reportError(openError, request)
      return
    }
    if (reloading && editVersion() !== request.editVersion) {
      reportError("Canvas changed while the file was being read. Reload again to discard those edits.", request)
      return
    }
    const fileMode = supportsDirectSave && supportsWritableHandle(handle) ? "browser_file" : "save_copy"
    const writeGranted = fileMode === "browser_file" &&
      await handle.queryPermission({mode: "readwrite"}) === "granted"
    if (!isCurrent(request) || !reloading && workspace.hasUnsaved()) {
      reportError(openError, request)
      return
    }
    const reply = await send(reloading ? "selected-reload" : "selected-open", {
      filename: file.name,
      bytes,
      mode: fileMode,
      generation: request.generation,
      ...(reloading ? {edit_version: request.editVersion} : {}),
    })
    // A candidate owns no handle until the existing schema/dirty checks accept it.
    if (reply.ok && alive && generation() === reply.generation && mode() === fileMode) {
      selectedFile = {
        handle: fileMode === "browser_file" ? handle : null,
        filename: file.name,
        generation: reply.generation,
        revision: reply.revision,
        writeGranted,
      }
    }
  }

  const onInputChange = async () => {
    const request = pickerRequest
    pickerRequest = null
    const file = input.files[0]
    input.value = ""
    if (!request) return
    try {
      if (file) await acceptFile(request, file, null)
    } catch (error) {
      reportError(fileError(error), request)
    } finally {
      finishPicker(request)
    }
  }
  const onInputCancel = () => {
    const request = pickerRequest
    pickerRequest = null
    input.value = ""
    if (request) finishPicker(request)
  }
  input.addEventListener("change", onInputChange)
  input.addEventListener("cancel", onInputCancel)

  const open = (action = "open") => {
    if (busy || root.dataset.fileBusy === "true") return
    const request = {action, generation: generation(), filename: root.dataset.fileName, trigger: document.activeElement}
    if (action === "open") {
      document.activeElement?.blur()
      if (workspace.hasUnsaved()) {
        reportError(openError, request)
        return
      }
    } else if (workspace.hasUnsaved() && !window.confirm(
      mode() === "save_copy"
        ? `Discard unsaved canvas edits and select "${request.filename}" again to reload it?`
        : "Discard unsaved canvas edits and reload the selected file from disk?",
    )) return

    setBusy(true)
    // Start the flush, but never await it before opening the user-activated picker.
    try {
      const flushed = workspace.flushEdits()
      if (!flushed.ok) { finishPicker(request); return }
      request.settled = flushed.settled
    } catch (error) {
      reportError(fileError(error), request)
      finishPicker(request)
      return
    }
    request.editVersion = editVersion()
    if (action === "reload" && mode() === "browser_file") {
      const selected = selectedFile
      if (!selected || selected.generation !== request.generation) {
        reportError("The selected file is no longer connected to this tab. Open it again to reload it.", request)
        finishPicker(request)
        return
      }
      ;(async () => {
        try {
          await acceptFile(request, await selected.handle.getFile(), selected.handle)
        } catch (error) {
          reportError(fileError(error), request)
        } finally {
          finishPicker(request)
        }
      })()
    } else if (action === "open" && supportsDirectSave) {
      // This call must stay in the original click/keyboard gesture, before any await.
      let picker
      try {
        picker = window.showOpenFilePicker({
          multiple: false,
          types: [{description: "Canvas JSON", accept: {"application/json": [".json"]}}],
        })
      } catch (error) {
        reportError(fileError(error), request)
        finishPicker(request)
        return
      }
      ;(async () => {
        let handle
        try {
          ;[handle] = await picker
        } catch (error) {
          // AbortError is the picker's native cancellation, not a read/write fallback.
          if (error.name !== "AbortError") reportError(fileError(error), request)
          finishPicker(request)
          return
        }
        try {
          await acceptFile(request, await handle.getFile(), handle)
        } catch (error) {
          reportError(fileError(error), request)
        } finally {
          finishPicker(request)
        }
      })()
    } else {
      pickerRequest = request
      // Reset before every dialog so choosing the same file emits change again.
      input.value = ""
      try {
        input.click()
      } catch (error) {
        pickerRequest = null
        reportError(fileError(error), request)
        finishPicker(request)
      }
    }
  }

  const newCanvas = async () => {
    const request = {generation: generation()}
    if (busy || root.dataset.fileBusy === "true") {
      reportError("Wait for the current file operation to finish before starting a new canvas.", request)
      return
    }
    setBusy(true)
    try {
      const flushed = workspace.flushEdits()
      if (!flushed.ok) return
      await flushed.settled
      if (!isCurrent(request)) return
      if (workspace.hasUnsaved()) {
        reportError("Save or reload this canvas before starting a new canvas.", request)
        return
      }
      const reply = await send("new", {generation: request.generation})
      if (reply.ok && alive && generation() === reply.generation) {
        selectedFile = null
        workspace.focusCanvasWhenReady(reply.generation)
      }
    } catch (error) {
      reportError(error.message, request)
    } finally {
      setBusy(false)
    }
  }

  const downloadCopy = reply => {
    const url = URL.createObjectURL(new Blob([reply.bytes], {type: "application/json"}))
    let link
    try {
      link = document.createElement("a")
      link.href = url
      link.download = reply.filename
      root.append(link)
      link.click()
    } finally {
      link?.remove()
      setTimeout(() => URL.revokeObjectURL(url), 0)
    }
  }

  const saveCopy = async (conversion = false) => {
    if (busy || root.dataset.fileBusy === "true" || mode() === "none") return
    const request = {generation: generation(), trigger: document.activeElement, action: conversion ? "version-copy" : "save-copy"}
    let reply
    setBusy(true)
    try {
      const flushed = workspace.flushEdits()
      if (!flushed.ok) return
      await flushed.settled
      if (!isCurrent(request)) return
      reply = await send(request.action, {generation: request.generation})
      if (!reply.ok || !reply.token) return
      if (!isCurrent(request) || reply.generation !== request.generation) {
        throw new Error("The canvas changed before the copy could be downloaded. Nothing was overwritten.")
      }
      downloadCopy(reply)
      const acknowledgment = await send(conversion ? "selected-version-copy-downloaded" : "selected-copy-downloaded", {token: reply.token, generation: reply.generation})
      if (!acknowledgment.ok) throw new Error("Copy download started, but the canvas could not acknowledge it. Disk persistence is not confirmed.")
    } catch (error) {
      const message = `Could not complete ${conversion ? "separate v2 copy" : "Save a copy"}: ${error.message}`
      if (reply?.token) {
        await send("selected-save-error", {token: reply.token, generation: reply.generation, message})
      } else if (isCurrent(request)) workspace.pushEvent("selected-error", {generation: request.generation, action: request.action, message})
    } finally {
      setBusy(false)
      if (isCurrent(request) && request.trigger?.isConnected && document.activeElement === document.body) {
        request.trigger.focus({preventScroll: true})
      }
    }
  }

  const save = async () => {
    if (busy || root.dataset.fileBusy === "true" || mode() === "none") return
    const request = {generation: generation(), filename: root.dataset.fileName || "untitled.json"}
    const originalMode = mode()
    let selected = selectedFile
    let reply
    let written = false
    let firstHandle = null
    setBusy(true)
    try {
      let permission
      let picker
      if (originalMode === "untitled" && supportsNewSave) {
        // Invoke in the original gesture: flushing/blur and server replies may consume activation.
        picker = window.showSaveFilePicker({
          suggestedName: request.filename,
          types: [{description: "Canvas JSON", accept: {"application/json": [".json"]}}],
        }).then(handle => ({handle}), error => ({error}))
      } else if (originalMode === "browser_file") {
        if (!selected?.handle || selected.generation !== request.generation) {
          throw new Error("The selected file is no longer connected to this tab. Open it again before saving.")
        }
        permission = selected.writeGranted
          ? Promise.resolve("granted")
          : selected.handle.requestPermission({mode: "readwrite"})
      }
      const flushed = workspace.flushEdits()
      // Attach rejection handlers immediately, even when a draft blocks the save.
      const chosen = picker
      const permissionGranted = permission?.then(result => {
        selected.writeGranted = result === "granted"
        if (!selected.writeGranted) throw new DOMException("Write permission denied", "NotAllowedError")
      })
      const [candidate] = await Promise.all([chosen, permissionGranted, flushed.ok ? flushed.settled : undefined])
      if (candidate?.error) throw candidate.error
      if (!flushed.ok || !isCurrent(request)) return
      if (candidate) {
        if (!supportsWritableHandle(candidate.handle)) throw new Error("The chosen file does not support writable file handles.")
        firstHandle = candidate.handle
      }
      const targetMode = originalMode === "untitled" ? (firstHandle ? "browser_file" : "save_copy") : originalMode
      reply = await send("save", {
        generation: request.generation,
        ...(originalMode === "untitled" ? {mode: targetMode, filename: firstHandle?.name || request.filename} : {}),
      })
      if (!reply.ok || !reply.token) return
      if (!isCurrent(request) || reply.generation !== request.generation || reply.mode !== targetMode ||
          mode() !== originalMode ||
          originalMode === "browser_file" && (!selected || selected !== selectedFile ||
            selected.generation !== request.generation || selected.revision !== reply.revision)) {
        throw new Error("The selected file changed before saving. Nothing was overwritten.")
      }
      if (reply.mode === "save_copy") {
        downloadCopy(reply)
        await send("selected-copy-downloaded", {token: reply.token, generation: reply.generation})
        return
      }
      const handle = firstHandle || selected.handle
      if (!firstHandle) await checkRevision(handle, reply.revision)
      const writable = await handle.createWritable({mode: "exclusive"})
      try {
        if (!isCurrent(request)) throw new Error("The canvas changed before saving. Nothing was overwritten.")
        await writable.write(reply.bytes)
        if (!firstHandle) await checkRevision(handle, reply.revision)
        if (!isCurrent(request)) throw new Error("The canvas changed while saving. Nothing was overwritten.")
        await writable.close()
        written = true
      } catch (error) {
        try {
          await writable.abort()
        } catch (abortError) {
          error.message += ` Temporary write cleanup failed: ${abortError.message}`
        }
        throw error
      }
      if (!isCurrent(request)) throw new Error("The file was written, but this canvas is no longer open. Reopen that file before saving again.")
      const acknowledgment = await send("selected-saved", {token: reply.token, generation: reply.generation})
      if (!acknowledgment.ok) throw new Error("The file was written, but the canvas could not confirm the save. Reload before saving again.")
      if (isCurrent(request)) {
        if (firstHandle && mode() === "browser_file") {
          selectedFile = {handle, filename: reply.filename, generation: request.generation,
            revision: reply.saved_revision, writeGranted: true}
        } else if (selectedFile === selected) selected.revision = reply.saved_revision
      }
    } catch (error) {
      if (error.name === "NotAllowedError" && selected) selected.writeGranted = false
      if (error.name === "AbortError" && !reply?.token) return
      const message = written ? error.message : fileError(error, true)
      if (reply?.token) {
        await send("selected-save-error", {
          token: reply.token, generation: reply.generation, message,
          status: error.fileStatus || (error.name === "NotFoundError" ? "unavailable" : undefined),
        })
      } else reportError(message, request)
    } finally {
      setBusy(false)
    }
  }

  syncButtons()

  return {
    newCanvas,
    open: () => open("open"),
    reload: () => open("reload"),
    save,
    saveCopy: () => saveCopy(false),
    convertVersionCopy: () => saveCopy(true),
    updated() {
      if (selectedFile && (selectedFile.generation !== generation() || selectedFile.filename !== root.dataset.fileName || ["server_file", "none", "untitled"].includes(mode()))) {
        selectedFile = null
      }
      syncButtons()
    },
    destroyed() {
      alive = false
      selectedFile = null
      pickerRequest = null
      input.removeEventListener("change", onInputChange)
      input.removeEventListener("cancel", onInputCancel)
    },
  }
}
