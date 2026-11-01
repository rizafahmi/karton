// Accessible alternatives to pointer-only drawing gestures. Mutations use
// Hakushi's public events, retaining its validation, locks, history and metadata.
export function mountObjectProperties(canvas) {
  const element = (tag, attrs = {}, text) => {
    const el = document.createElement(tag)
    for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value)
    if (text !== undefined) el.textContent = text
    return el
  }
  const button = (text, action) => {
    const el = element("button", {type: "button"}, text)
    el.addEventListener("click", action)
    return el
  }
  const panel = element("div", {id: `${canvas.id}-properties`, class: "object-properties", popover: "auto", role: "dialog", "aria-label": "Object properties"})
  const trigger = element("button", {type: "button", class: "hakushi-control properties-toggle", popovertarget: panel.id, "aria-label": "Object properties", "aria-keyshortcuts": "P", title: "Object properties (P)"}, "Edit")
  canvas.controlsEl.append(trigger, panel)
  const help = element("div", {id: `${canvas.id}-keyboard-help`, class: "object-properties keyboard-help", popover: "auto", role: "dialog", "aria-label": "Keyboard shortcuts", tabindex: "-1"})
  const helpTrigger = element("button", {type: "button", class: "hakushi-control", popovertarget: help.id, "aria-label": "Keyboard shortcuts", "aria-keyshortcuts": "Shift+/", title: "Keyboard shortcuts (?)"}, "?")
  help.append(element("h2", {}, "Keyboard shortcuts"))
  for (const [heading, text] of [
    ["Focus and panels", "Tab / Shift+Tab reaches every control. Enter or Space activates buttons; native selects use arrows. Tab from the canvas visits objects, then controls; Shift+Tab returns. Escape closes a popover or menu and returns to its trigger. P opens Edit / Object properties; ? opens this help, only with canvas focus. Style contains all fill, stroke, width, dash, corner, size, alignment, arrowhead and text-style choices; select an object first."],
    ["Draw and edit", "With canvas focus: V selects; R rectangle, O ellipse, D diamond, I triangle, T text, L line, A arrow. Choose a drawing tool then Enter on the canvas to place it at the viewport center. Tab to the new object; Enter or F2 edits shape text. Escape cancels text, blur commits (Save commits first). Object properties provides exact X/Y, width/height, rotation, and absolute line start/end coordinates. Apply geometry commits; Close or Escape discards unsubmitted fields. Locked objects cannot be edited."],
    ["Selection and movement", "Tab visits objects. Alt+arrows focuses the nearest object. Edit → Objects lists labeled checkboxes: Tab to each object and Space to toggle any subset, then Select objects applies it. Command/Ctrl+A selects all on the canvas. Arrows move selected unlocked objects by 1 pixel; Shift+arrows by 10. A focused line endpoint uses the same steps. With no selection arrows pan; Shift pans farther. Space+drag also pans."],
    ["Connections", "C on an object starts a connected arrow; arrows or Tab cycle targets, Enter creates it, Escape cancels. Edit → Connections reaches every existing connection: selecting one highlights it. Choose source/target objects and sides, then Create / reconnect. New connection creates an arrow; existing connection keeps its metadata and appearance. For a self-loop choose the same object and two different named sides. Apply label and Delete connection edit the chosen arrow. Change geometry or Style of standalone arrows as objects, not connections."],
    ["Clipboard and history", "With canvas focus: Command/Ctrl+C copy, X cut, V paste, D duplicate; Delete/Backspace deletes selected objects or connections. Command/Ctrl+Z undo; Shift+Z or Ctrl+Y redo. Bring to front / Send to back are in the rail; Command/Ctrl+Shift+] / [ does the same. Each effective command participates in history."],
    ["Arrange and view", "Shift+L tidies. Tidy and the layout picker in the rail offer every supported layout. Zoom percentage opens zoom out/in, Fit to screen, Reset to 100%. With canvas focus: + / − or Command/Ctrl + / − zoom the canvas; Shift+1 fits, Shift+0 or Command/Ctrl+0 resets. Outside canvas focus Command/Ctrl + / − / 0 remains browser page zoom, including form fields and toolbar controls. Paper opens the native paper picker."],
    ["Files", "Command/Ctrl+S saves from anywhere (including shape text). Command/Ctrl+O opens the existing native file picker; Command/Ctrl+Shift+E downloads an image. Save writes a server path or permitted browser handle; Save copy downloads without clearing unsaved edits. Document menu → Open… uses the OS picker. Advanced server file path contains actual open/create forms; it never pretends to create a browser file. Reload rereads the current source or asks to choose a copy again, confirming unsaved loss. Default text style, project links and all file actions are Tab reachable. Download exports an image. Browser New, Reload, Find and other system shortcuts are not reassigned."],
    ["Scope", "Single-letter commands operate only on the focused canvas or object, never in fields, selects, contenteditable text, or during IME composition. Focus a toolbar control or field to use browser shortcuts normally. This is keyboard reachability, not a claim of screen-reader or cross-browser certification."]
  ]) help.append(element("h3", {}, heading), element("p", {}, text))
  help.append(button("Close keyboard shortcuts", () => help.hidePopover()))
  canvas.controlsEl.append(helpTrigger, help)
  help.addEventListener("toggle", event => {
    if (event.newState === "open") {
      help.scrollTop = 0
      help.focus({preventScroll: true})
    }
  })
  panel.append(element("h2", {}, "Object properties"))
  panel.append(element("p", {}, "Select objects, edit exact geometry, or create and reconnect arrows. Style contains appearance choices."))
  const field = (form, label, type = "number", options) => {
    const id = `${panel.id}-${label.toLowerCase().replaceAll(/[^a-z0-9]+/g, "-")}`
    const input = element(options ? "select" : "input", {id, name: label})
    if (options) for (const [value, text] of options) input.append(element("option", {value}, text))
    else { input.type = type; if (type === "number") { input.step = "any"; input.required = true } }
    form.append(element("label", {for: id}, label), input)
    return input
  }
  const send = (event, payload, after) => canvas.push(event, payload, reply => {
    if (reply.error || reply.ok === false) canvas.announce(reply.error || "Edit was refused.")
    else requestAnimationFrame(() => after?.(reply))
  })
  const objects = element("div")
  panel.append(objects)
  const objectGroup = element("fieldset", {class: "properties-objects"})
  const nodeChoices = element("div")
  objectGroup.append(element("legend", {}, "Objects"), nodeChoices)
  objects.append(objectGroup)
  const selectObjects = button("Select objects", () => {
    canvas.selectedEdges.clear()
    canvas.setSelection(new Set([...nodeChoices.querySelectorAll("input:checked")].map(input => input.value)))
    canvas.selectionChanged()
    canvas.revealNodes([...canvas.selected])
    refreshGeometry()
  })
  objects.append(selectObjects)
  const geometry = element("form")
  geometry.append(element("h3", {}, "Geometry — one unlocked object"))
  const values = Object.fromEntries(["X", "Y", "Width", "Height", "Rotation", "Start X", "Start Y", "End X", "End Y"].map(name => [name, field(geometry, name)]))
  values.Width.min = values.Height.min = "0.1"
  const apply = element("button", {type: "submit"}, "Apply geometry")
  geometry.append(apply)
  panel.append(geometry)
  const single = () => canvas.selected.size === 1 ? canvas.nodes.get([...canvas.selected][0]) : null
  function refreshGeometry() {
    const node = single()
    const line = node?.type === "shape-line"
    for (const [name, input] of Object.entries(values)) {
      const endpoint = name.includes(" ")
      input.closest("form").querySelector(`label[for="${input.id}"]`).hidden = input.hidden = endpoint !== !!line && (endpoint || line)
      input.disabled = !node || node.locked || (line ? !endpoint : endpoint)
    }
    apply.disabled = !node || node.locked
    if (!node) return
    const style = JSON.parse(node.el.querySelector("[data-hakushi-style]")?.dataset.hakushiStyle || "{}")
    for (const [name, value] of Object.entries({X: node.x, Y: node.y, Width: node.width, Height: node.height, Rotation: style.rotation || 0})) values[name].value = value
    if (line) {
      const aim = node.el.querySelector(".hakushi-shape-line-aim")
      for (const [name, attr, offset] of [["Start X", "x1", node.x], ["Start Y", "y1", node.y], ["End X", "x2", node.x], ["End Y", "y2", node.y]]) values[name].value = Number(aim.getAttribute(attr)) + offset
    }
  }
  geometry.addEventListener("submit", event => {
    event.preventDefault()
    const node = single()
    if (!node || node.locked || canvas.gesture) return
    const number = name => Number(values[name].value)
    if (node.type === "shape-line") {
      const [x1, y1, x2, y2] = ["Start X", "Start Y", "End X", "End Y"].map(number)
      const aim = node.el.querySelector(".hakushi-shape-line-aim")
      if ([x1, y1, x2, y2].every((value, index) => value === Number(aim.getAttribute(["x1", "y1", "x2", "y2"][index])) + (index % 2 ? node.y : node.x))) return
      const x = Math.min(x1, x2) - 12, y = Math.min(y1, y2) - 12
      send("hakushi:edit", {node: node.id, action: "endpoints", from: [x1 - x, y1 - y], to: [x2 - x, y2 - y], box: [x, y, Math.abs(x2 - x1) + 24, Math.abs(y2 - y1) + 24]}, refreshGeometry)
    } else {
      const box = ["X", "Y", "Width", "Height"].map(number)
      const moved = box.some((value, index) => value !== [node.x, node.y, node.width, node.height][index])
      const rotated = number("Rotation") !== Number(JSON.parse(node.el.querySelector("[data-hakushi-style]")?.dataset.hakushiStyle || "{}").rotation || 0)
      if (rotated) send("hakushi:edit", {node: node.id, action: "rotate", value: number("Rotation"), ...(moved ? {box} : {})}, refreshGeometry)
      else if (moved) send("hakushi:change", {op: "move", nodes: [{id: node.id, x: box[0], y: box[1], width: box[2], height: box[3]}]}, refreshGeometry)
    }
  })
  geometry.append(button("Edit text", () => {
    const node = single()
    if (node && !node.locked && node.type === "shape") { panel.hidePopover(); canvas.editText(node) }
  }))
  const connections = element("form")
  connections.append(element("h3", {}, "Connections"))
  const edges = field(connections, "Connection", "text", [])
  const source = field(connections, "Source object", "text", [])
  const sourceHandle = field(connections, "Source side", "text", ["right", "bottom", "left", "top"].map(side => [side, side]))
  const target = field(connections, "Target object", "text", [])
  const targetHandle = field(connections, "Target side", "text", ["left", "top", "right", "bottom"].map(side => [side, side]))
  const label = field(connections, "Connection label", "text")
  label.maxLength = 500
  const showEdge = () => {
    const edge = canvas.edges.get(edges.value)
    canvas.selectedEdges.clear()
    if (edge) {
      canvas.setSelection(new Set())
      canvas.selectedEdges.add(edge.id)
      source.value = edge.source; target.value = edge.target
      sourceHandle.value = edge.sourceHandle || ""; targetHandle.value = edge.targetHandle || ""
      label.value = edge.label || ""
      canvas.revealNodes([edge.source, edge.target])
    } else label.value = ""
    canvas.selectionChanged()
  }
  for (const select of [sourceHandle, targetHandle]) select.prepend(element("option", {value: ""}, "Automatic"))
  edges.addEventListener("change", showEdge)
  connections.append(element("button", {type: "submit"}, "Create / reconnect"))
  connections.addEventListener("submit", event => {
    event.preventDefault()
    const ends = {source: source.value, sourceHandle: sourceHandle.value || null, target: target.value, targetHandle: targetHandle.value || null}
    if (!ends.source || !ends.target) return canvas.announce("Choose source and target objects.")
    if (ends.source === ends.target && (!ends.sourceHandle || !ends.targetHandle || ends.sourceHandle === ends.targetHandle)) return canvas.announce("A self-loop needs two different named sides.")
    const id = edges.value
    const before = new Set(canvas.edges.keys())
    send("hakushi:change", {op: id ? "reconnect" : "connect", edges: [{...ends, ...(id ? {id} : {})}]}, () => {
      const added = [...canvas.edges.values()].find(edge => !before.has(edge.id))
      canvas.selectedEdges.clear()
      if (id || added) canvas.selectedEdges.add(id || added.id)
      refresh()
      canvas.selectionChanged()
    })
  })
  connections.append(button("Apply label", () => {
    if (edges.value) send("hakushi:change", {op: "update", edges: [{id: edges.value, label: label.value}]}, refresh)
  }), button("Delete connection", () => {
    if (edges.value) send("hakushi:change", {op: "delete", nodes: [], edges: [edges.value]}, () => { canvas.selectedEdges.clear(); canvas.selectionChanged(); refresh() })
  }))
  panel.append(connections, button("Close", () => panel.hidePopover()))
  const options = (select, choices) => {
    const old = select.value
    select.replaceChildren(...choices.map(([value, text]) => element("option", {value}, text)))
    if ([...select.options].some(option => option.value === old)) select.value = old
  }
  function refresh() {
    const nodes = [...canvas.nodes.values()].filter(node => !canvas.gone.has(node.id))
    const choices = nodes.map(node => [node.id, `${node.label || node.type} · ${node.id}${node.locked ? " (locked)" : ""}`])
    nodeChoices.replaceChildren(...choices.map(([id, text], index) => {
      const input = element("input", {type: "checkbox", id: `${panel.id}-object-${index}`, value: id})
      input.checked = canvas.selected.has(id)
      const row = element("div", {class: "properties-object"})
      row.append(input, element("label", {for: input.id}, text))
      return row
    }))
    for (const select of [source, target]) options(select, choices.filter(([id]) => !canvas.nodes.get(id).locked && canvas.nodes.get(id).type === "shape"))
    options(edges, [["", "New connection"], ...[...canvas.edges.values()].map(edge => [edge.id, `${edge.label || "Arrow"} · ${edge.id}`])])
    const selected = [...canvas.selectedEdges][0]
    if (selected) { edges.value = selected; showEdge() }
    refreshGeometry()
  }
  panel.addEventListener("beforetoggle", event => { if (event.newState === "open") refresh() })
  panel.addEventListener("toggle", event => {
    trigger.setAttribute("aria-expanded", String(event.newState === "open"))
    if (event.newState === "open") (nodeChoices.querySelector("input") || selectObjects).focus()
  })
  return {open: () => { trigger.focus(); panel.showPopover() }, help: () => { helpTrigger.focus(); help.showPopover() }, destroy: () => { trigger.remove(); panel.remove(); helpTrigger.remove(); help.remove() }}
}
