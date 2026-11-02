# MVP plan

Planning only: unchecked work is not implemented behavior. Approved sequence:
current web editing (front/back → connected-arrow styling), then independent
native macOS. The separately approved adjacent-thought task below is implemented;
connected-arrow styling and native work are not advanced by it. Proposed readiness
additions below are **not approved scope or a new milestone blocking native**;
decide their adoption and placement explicitly.
No app scaffolding, toolchain installation, dependencies, build steps, or CI
changes until implementation is requested.

## Product outcome and existing baseline

**MVP outcome:** turn an idea into a useful spatial diagram, preserve it as an
ordinary local JSON document, return to it safely, and use it in a presentation.
Completing web-editing slices alone is web-slice completion, not product-MVP
proof. Choose the primary job: recommend individual brainstorming/systems
diagrams → presentation, not four equal feature sets. Facilitated use can be
single-driver, not multiplayer. Agree the intended user and which editor
completes this journey.

Keep the [version-1 contract](README.md#document-format-version-1),
local-file-first trust boundary, and [agent policy](AGENTS.md). No database,
accounts, cloud, collaboration, automatic merging, or full native/web parity is
implied. Discuss format changes before implementation; preserve existing v1
files.

**Source-backed baseline, not fresh runtime certification:**

- Shapes/text, standalone Line/Arrow, bound arrows/self-loops, geometry editing,
  and undo/redo form the existing [editing workflow](README.md#edit).
- `Document.decode/prepare_save` validate v1; encoding retains metadata, stable
  IDs, stacking, geometry, named colors, and font roles. Hakushi owns
  graph/history.
- `Document.save/replace` check revisions and use a sibling file;
  `mountNativeFile` handles source modes. `CanvasLive.selected-saved` retains
  newer dirty edits. See [persistence behavior and limits](README.md#edit).
- Web image Download exists (`CanvasLive.render`, `export={true}`), with font
  readiness in `app.js`; output quality/browser behavior still need actual
  proof.
- [Examples](README.md#examples) are real editable boards, not disposable
  fixtures.

Use existing [checks](README.md#checks) and temporary documents for acceptance.
Record commands, browsers/platforms, actual saved/exported artifacts, and
limits; passing tests or a source inspection alone is not a completed user
journey.

## Current milestone: web editing

### 1. Bring selected drawing objects to front / send to back

- [x] **Outcome:** control which overlapping drawing objects appear above
      others.
- **Scope:** Bring to front and Send to back for selected drawing nodes, using
  existing version-1 `nodes` array order (back to front). No full layer panel,
  auto-layout, or new lock semantics.
- **Acceptance:** only stacking changes; preserve all objects' positions,
  styles, metadata, and connections. Follow existing selection behavior; retain
  selected objects' relative order and unselected objects' relative order. No
  selection or an already-front/back selection must not cause spurious document
  changes, dirty state, or history entries.
- **Proof:** overlap several objects, select and reorder in both directions;
  each effective command is one undoable action, with redo restoring the order.
  Check no-selection, already-front/back, and multi-selection cases. Save a
  temporary document, inspect `nodes` order, and reopen to confirm overlap
  survives without geometry, style, or connection changes.
- **Verified (2026-11-01):** actual Brave/Chromium 156 on macOS: overlapping
  objects, reverse-click multi-selection, front/back, single-step undo/redo,
  interleaved move history, empty/extreme/edge-only/locked no-ops, keyboard
  activation, and 640×480 with Style and arrangement options open. A genuine
  temporary server-file Save and reopen retained stacking and authored geometry,
  styles, metadata, and connections (normal serializer defaults only). Automated
  behavior regressions pass. Safari, Firefox, and Edge were not exercised;
  narrow desktop checks are not mobile interaction proof.

### Adjacent thought from a focused shape

- [x] **Approved outcome:** keep thinking through the keyboard: focused existing
      text-bearing shape → N → cardinal direction → immediate inline typing →
      Enter adds one independent thought and focuses it for the next N.
- **Scope:** fresh upright 160×96-minimum rectangle with document-default style
  and typography, no source clone or automatic link. Full measured text growth,
  rotated-node bounds plus 48 world-pixel clearance, and same-ray blocker skipping
  affect only the new box. The bounded inline editor can scroll; reveal pans or
  reduces zoom only for width or a minimum one-line editing viewport with normal
  padding and a screen-sized hint. No schema, dependency, properties panel, global
  layout, connected-arrow styling, or native implementation changes.
- **Safety:** client-only drafts cancel without graph/dirty/history/redo changes;
  placed blank/whitespace text is allowed. Final text and geometry add in one
  ordinary history action; redo restores identity. Save flushes before writing,
  invalid text blocks persistence, Open/unload keep unsaved guards, and the
  existing 2,000-grapheme limit refuses without truncating the draft.
- **Verified (2026-11-01):** independent actual Brave (Chrome/156.0.8078.80 engine)
  proof on macOS temporary server files covered chained N growth, all cardinal
  directions after pan/zoom, rotated blockers, measured multiline growth,
  bounded caret/error visibility,
  one-step undo/redo without injected recovery focus, Save button and Mod+S,
  disk-byte-preserving cancellation/overlong refusal, blank/whitespace additions,
  draft status, unsaved unload refusal, guards and existing selection/pan/C/stack
  routes. A real paused-server reply proved a sole readonly editor and intact
  text across rapid pending-reply re-entry, then one add after acknowledgement.
  Automated state/math and LiveView persistence/history regressions pass.
- **Limits:** this is not screen-reader, real OS IME/focus-switch, native
  permissions/picker, or cross-browser certification. Existing source-mode
  persistence contracts remain unchanged; unrelated readiness/native checkboxes
  below retain their prior state.

### 2. Style connected arrows

- [x] **Outcome:** select a connected arrow and edit its agreed appearance.
- **Approved (2026-11-02):** optional `edge.data.connector_style` with named
  `stroke`, numeric `width` 1/2/4 and boolean `dash`, rendered through existing
  Style. Version remains 1; omission preserves legacy appearance (including
  animation); explicit solid retains `animated`. Existing marker semantics stay.
  Unknown metadata remains preserved; wrong-shaped style objects refuse editing
  atomically. Older readers preserve metadata without rendering new styles.
- **Scope:** connected arrows, not a duplicate standalone-line inspector:
  standalone Line/Arrow already expose Style color, width, dash, and heads.
  Reuse the existing style vocabulary for supported properties; preserve
  bindings, self-loops, and the free-standing Line tool. No new attachment
  behavior.
- **Acceptance/proof:** select a connected arrow → apply each agreed style →
  move its endpoint shapes → undo/redo → save and reopen a temporary document.
  Check ordinary connections and self-loops retain their bindings and
  appearance; style edits undo/redo correctly, unrelated objects remain
  unchanged, and plain Lines remain free-standing. Inspect saved bytes against
  the agreed file contract.
- **Verified (2026-11-02):** actual bundled editor in managed
  HeadlessChrome 150 on macOS, at 1200×800 and 360×480: ordinary animated edge
  and self-loop color/width/solid/dashed controls, legacy omission versus explicit
  Ink, one-step/interleaved history, saved-value no-op, atomic edge multiselection,
  mixed-selection node inspector, visible metadata-collision refusal, both endpoint
  shape moves, genuine temporary server-file Save and reopen. Saved bytes retained
  endpoints/handles, labels/routes/markers/animation, unknown metadata, unrelated
  objects and standalone Line. Selected/connected/hover line and target marker
  colors matched, including simultaneous same-palette edges in different states;
  invisible strokes retained 14px hit paths. Actual selected-edge SVG export,
  reopened as a browser document, rendered authored red dashed strokes and red
  markers (not selection cobalt). S/Tab focus entry, after-server-patch Escape
  dismissal/focus return and narrow panel fit were exercised: styleOpen=false,
  toggle aria-pressed=false, panel display:none, focus style-toggle (the existing
  toggle has no aria-expanded attribute). Full Mix and existing Node regressions pass.
- **Limits:** SVG artifact/rendering proof, not PNG pixel proof. No Safari,
  Firefox, Edge, forced-colors, screen-reader, physical OS IME or native-picker
  certification. Selection setup used existing canvas hooks where needed; edits
  used visible controls and endpoint moves used actual pointer gestures. Native
  work remains final; proposed readiness additions below are still unapproved.

## Next milestone: independent native macOS editor

- [ ] **Outcome:** open an existing version-1 JSON canvas in an independent
      native Mac editor, select/move objects, edit text, undo/redo, save, and
      reopen in both editors; export a transparent high-resolution PNG suitable
      for Keynote.
- **Purpose:** personal structured brainstorming, developer systems diagrams,
  facilitated sessions, and illustrations for presentations.
- **Committed direction:** native UI follows Apple Human Interface Guidelines,
  not Neo-Acid. No wrapper, webview, Phoenix server, or BEAM runtime in the Mac
  app. Share the [version-1 file contract](README.md#document-format-version-1),
  not a runtime; preserve authored geometry, semantic font roles, and named
  colors. Native font/palette resolution may differ; pixel-identical rendering
  is not required.
- **Before project creation:** confirm repository organization. Recommended, not
  approved: monorepo with the web app left at the root, a separate `macos/`
  project, and shared contract fixtures; independent builds and runtimes. Swift
  with AppKit, SwiftUI, and Core Graphics is a candidate, not an approved
  architecture.
- **Before implementation:** decide minimum macOS, SwiftUI/AppKit
  responsibilities, the initial supported document-content/editing scope, and
  PNG default dimensions and maximum output size. Do not imply full web feature
  parity.
- **Compatibility gate:** agree fixtures covering supported shapes/text,
  standalone lines, connections/self-loops, rotations, locks, and metadata.
  Unsupported content must be identified before editing: reject it clearly or
  open read-only without loss; never silently omit it or permit a lossy save.
- **Round-trip proof:** on temporary fixture copies, open → render → select/move
  → edit text → undo/redo → save → reopen in web and native. Compare actual
  JSON: stable IDs, node stacking order, bindings and handles, styles, unknown
  metadata, named colors/font roles, and unedited authored geometry survive;
  only intended edits differ. Plain Line remains free-standing. Renderer
  font/theme choices must not dirty files.
- **Mac workflow proof:** native menus, keyboard commands, file dialogs, and
  window lifecycle work together. Exercise dirty close/quit/open prompts,
  cancel, invalid files, failed writes, and external-change conflicts; keep
  edits and source intact. Use atomic replacement with conflict checks; document
  remaining race/durability limits rather than claiming filesystem locking.
- **PNG proof:** choose explicit output pixel width/height or scale, independent
  of viewport zoom and screen DPR. Wait for resolved fonts; include padding and
  full labels/strokes/arrowheads, with true alpha and no paper/grid/UI
  background. Inspect actual PNG dimensions/alpha, compare exports at different
  zoom/DPR, and place the export on actual light and dark Keynote slides to
  check transparency, legibility, and unclipped content. No SVG/PDF requirement
  in this milestone.
- **Boundary:** a small complete native workflow, not web parity, cloud,
  accounts, multiplayer, or additional platforms. Implementation must supply
  native setup and proof instructions; current Mix/browser instructions remain
  web-only.

### Native delivery tasks within this milestone

- [ ] Resolve native decisions before project creation/implementation as
      applicable.
- [ ] Agree compatibility fixtures and prove round-trips before editable saves.
- [ ] Deliver the agreed native workflow/history and failure/conflict proof.
      New/create/connect behavior remains unresolved, not implied by “editor.”
- [ ] Meet the PNG/Keynote gate using actual exported files.
- [ ] Supply audience-appropriate setup/launch/check instructions and prove
      runtime independence; decide install/distribution needs before release
      infrastructure.

## Proposed readiness additions — adoption and placement need approval

Source-backed gaps and observed/unverified risks below do not reorder approved
work.

### 1. Preserve edits when the original cannot be saved

- [ ] **Proposed outcome:** save a separate JSON preservation copy from any
      source mode without discarding edits or overwriting the conflicted
      original.
- **Evidence:** `Document.current_revision` refuses changed/missing sources;
  `CanvasLive` blocks open/create while dirty and its disk warning offers
  Reload. `native_file.js` downloads JSON only in `save_copy` mode. A
  separate-copy escape for `server_file`/`browser_file` is absent from the
  current UI path; this is source-backed, not a runtime-reproduced UI bug.
- **Acceptance:** edit a temporary canvas, change/remove its source externally
  or deny writing, then preserve elsewhere. Inspect the new JSON for the latest
  graph, pending text, and metadata; reopen it. Original bytes remain untouched,
  and the original source/conflict/dirty state stays truthful. Cancel/failure
  retain edits. A downloaded copy must not imply confirmed original-file
  persistence. No automatic merge or silent source reassignment.

### 2. Start and keep a first personal document safely

- [ ] **Proposed outcome:** the intended first-time user can install/launch,
      create their own board, and choose where to keep it without editing the
      welcome source accidentally or confusing a browser filename with a server
      path.
- **Evidence:** startup opens editable `examples/welcome.json`; Create is under
  Advanced: server file path (`CanvasLive.render`), not an ordinary New/Save As
  flow.
- **Acceptance:** from the agreed starting environment, follow canonical launch
  instructions, create/edit/save/reopen a personal document, inspect
  bytes/location, and check cancellation/failure/existing-file protection.
  Decide audience and improvements first, not an assumed installer or universal
  browser file-write API.

### 3. Make resilience and recovery an explicit promise

- [ ] **Proposed gate:** decide promises for transient disconnect, server
      restart, tab reload/close, and crash. `CanvasLive.mount` loads the initial
      file; edits and tab-scoped browser handles are in memory. `beforeunload`
      is not crash recovery.
- **Acceptance:** exercise dirty graph, active text, and in-flight saves across
  agreed interruptions; inspect disk and recovered/current state, never falsely
  report Saved, and document retention/loss and safe continuation. Any local
  draft mechanism or automatic autosave requires a separate decision, not
  implied scope.

### 4. Prove usable editing on the intended setup

- [x] **Proposed gate:** keyboard access, focus, and short-window controls work
      through open/edit/style/reorder/connect/save and cancellation; include
      arrow controls when implementing their inspector. Do not infer
      accessibility from ARIA.
- Keyboard editing uses direct canvas interactions, not a properties panel:
  selection-preserving object/edge traversal, Space tap selection (hold+drag
  retains panning), G handle previews, staged C bindings and existing inline
  labels. S opens existing Style; the compact ? reference lives in the document
  menu. Preserve canvas/field/IME/browser-key boundaries and file/style focus
  return. This is not cross-browser or assistive-technology certification.
- **Direct-keyboard verification (2026-11-01, Brave/Chromium on macOS only):**
  actual keys exercised arbitrary selection; G commit/cancel, endpoints and
  Save/Open preview lifecycle; C creation, distinct-side self-loop, reconnect,
  inline label commit/cancel and undo; Style-open editor/mode Escape precedence;
  drawing-tool Enter after edge selection; history cancellation of previews;
  Space-held pointer panning with selection and clean state preserved; retained
  pointer drawing/move/resize/rotation; stable stacking and undo; pan/zoom/fit;
  field isolation and compact-menu scrolling/focus return. Genuine save/reopen
  retained 11 nodes, 2 connections, authored geometry and metadata with clean
  state and no observed application errors. Node geometry/selection/lifecycle
  regressions and full Mix tests supplement the browser proof.
- **Verification limits:** this session did not certify browser-chrome zoom,
  physical IME/AltGraph/dead-key entry, screen readers, other browsers, or
  OS-selected writable-handle permission dialogs. Preserve the existing native
  file capability/fallback contract; local-server and downloaded-file proof is
  not OS-dialog automation. Connected-arrow appearance and independent native
  editor work remain the separately agreed milestones above.
- Check short-window menus/inspectors for clipped actions, traps, and hidden
  focus.
- Agree a representative brainstorming/diagram board and intended
  hardware/browser. Exercise open, text editing, pan/zoom, save/reopen, and
  export; record responsiveness and failures. Choose acceptance expectations
  with the user, not invented time/node-count targets or upstream Hakushi
  benchmark claims. Optimize only measured problems; narrow-layout checks are
  not mobile-interaction proof.

## Product-MVP acceptance — proposed validation gate

- [ ] An intended user who did not implement the feature completes a real
      session: start → create or obtain an agreed starting board → develop a
      useful diagram → arrange/connect/style → save → close/reopen → present the
      output.
- Agree the primary scenario beforehand. Record help, lost work, persistence
  confusion, and usefulness. Ask whether local editable JSON, returning to edit,
  and presentation make this tool worth choosing; no source-derived market-fit
  claims, mandated telemetry, or invented time/scale/satisfaction metrics.
- Use actual temporary JSON and exported images as evidence; for native
  presentation acceptance use actual light/dark Keynote slides. Inspect intended
  edits and retained content, not just screenshots, callbacks, or a “Saved”
  label.
- Include one relevant save-conflict/cancellation scenario and the agreed
  recovery promise. A missing preservation path is an explicit release decision,
  not a checkbox covered by successful happy-path saves.
- Record web-slice, native-workflow, and overall product acceptance separately.
  Proposed gates become release requirements only after explicit scope approval.

## Later

- [ ] **File-menu usability:** scrolling already exists (`app.css`, max-height
      and overflow-y). Improve compactness, keyboard access, and short-window
      reachability; do not merely hide the scrollbar. Promotion into readiness
      is not yet approved.

Promote optional work only as ranked hypotheses grounded in observed session
friction.

## Needs decision

- [x] **Connected-arrow appearance:** approved (2026-11-02): color, width 1/2/4
      and dash in optional `edge.data.connector_style`, keeping version 1 and
      existing target marker semantics. See [edge contract](README.md#edges).
      No standalone arrowhead mapping or new attachment behavior is approved.
- [ ] **Native authoring:** recommend a minimal New → draw/text → connect
      workflow for brainstorming, but decide creation versus existing-document
      editing explicitly. If edit-only, identify where starting boards come from
      and describe that boundary honestly; neither decision implies full web
      parity.
- [ ] **Audience and delivery:** personal/developer setup versus broader users;
      agree first-install/launch expectations and native install/distribution
      needs. Do not presume signing, notarization, an app store, or a packaging
      toolchain.
- [ ] **Restart/local recovery:** agree supported interruption cases, loss
      warnings, and whether recovery beyond explicit save/preservation copies is
      required. Decide storage/lifetime/privacy implications before adding any
      local draft mechanism.
- [ ] **Native repository/technology:** confirm organization before project
      creation; decide minimum macOS, stack and UI/rendering responsibilities,
      supported content and editing scope, shared fixtures, and independent
      build/check instructions. The monorepo and Swift/AppKit/SwiftUI/Core
      Graphics proposal above is not approval.
- [ ] **PNG output:** agree default dimensions/scale and maximum output size;
      retain transparency, font readiness, clipping, zoom/DPR, and Keynote proof
      above.
- [ ] **Proposed readiness:** decide which additions become scope, their
      placement without silently delaying native, and the representative
      workload/user session.
- [ ] **Favicon (low priority):** logo/favicon assets and layout references
      exist; confirm a concrete branding gap before changing assets or marking
      work complete.

## Resolved design note

- **“Do we need nodes to connect an arrow/line so it follows when moved?”**
  Existing bound arrows already follow their endpoint shapes
  ([current behavior](README.md#edit)). Keep plain Line free-standing, including
  when drawn between shapes; do not turn the old question into attached-Line
  work.

## Done

- [x] redesign with acid theme
- [x] canvas styling using acid theme
- [x] canvas-focused zoom shortcuts; browser page zoom outside canvas focus
- [x] add a line
- [x] ability to do a loop with arrow/line
- [x] Do rotation, the drawing item is rotating, but the guide nodes stay still.
      I think it's a bug
- [x] Load file using os's native load file
