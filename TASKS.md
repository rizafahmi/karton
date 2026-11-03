# MVP plan

Planning only: unchecked work is not implemented behavior. Approved sequence:
current web editing (front/back → connected-arrow styling), then remaining
non-native work, with the independent native macOS editor as the final milestone.
The separately approved adjacent-thought task is implemented. Connected-arrow
styling's additive v1 metadata scope is now approved (details below); the native
editor remains last. Save a copy preservation is separately approved and
implemented below; other proposed readiness additions remain **unapproved scope**.
Decide their adoption and placement before the final native milestone.
No app scaffolding, toolchain installation, dependencies, build steps, or CI
changes until implementation is requested.
Repository preparation was explicitly requested on 2026-11-03: web at root,
`macos/` for the independent native project, and `shared/fixtures/v1/` for JSON
contract fixtures. This does not approve native app scaffolding, technology,
features, or the other proposed readiness work.

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
  work remains final; other proposed readiness additions below remain unapproved.

### First-class New canvas

- **Status:** implemented as an explicitly requested web workflow; this does not
  approve other proposed readiness additions below or move the native milestone.
- **Scope:** primary document-menu New canvas creates an in-memory `untitled.json`
  with Normal typography, a fresh generation and history, and no previous path or
  handle. Advanced server-path creation remains available. New flushes valid
  editors/drafts, then blocks unsaved work and pending persistence; invalid drafts
  remain intact. Ready-canvas focus supports immediate keyboard editing.
- **Persistence:** first native Save invokes the Save picker from the original
  gesture, writes validated v1 JSON, and only then promotes the saved snapshot to
  a browser-backed document. Later edits stay dirty and history is preserved.
  Unsupported saving downloads a copy, retaining the unsaved baseline rather than
  claiming a confirmed disk save. Reload selects an actual saved copy or reads the
  promoted handle; no phantom server source is introduced.
- **Contract and verification:** [README: Run](README.md#run) documents the state
  transitions and [manual verification](README.md#manual-browser-verification)
  includes New, dirty/draft/busy refusal, first-save failures, stale generations,
  real-picker versus handle-only proof, and downloaded-byte inspection. Native
  dialog, permissions, and cross-engine behavior require actual browser evidence;
  automated source-mode tests alone do not certify them.
- **Verified:** `node --check assets/js/app.js` and `mix check` passed (32 Node
  tests and 76 ExUnit tests). Actual Chromium editor checks showed clean New
  remounting an empty Normal-font board with ready-canvas focus and no old-file
  write; dirty edits, valid/invalid drafts and in-flight writes refused New.
  The same rejected 2,001-character draft was corrected through real typing,
  committed, and dirty-blocked New without changing generation. Actual downloaded
  JSON parsed as v1 with empty nodes/edges and sans typography, retaining honest
  dirty state. Cancelled copy reload preserved edits; the actual file chooser
  accepted a renamed downloaded copy and reloaded cleanly.
- **Handle proof and limits:** actual OPFS-backed writes verified first-save
  promotion only after success, subsequent in-place Save, conflict preservation,
  connected-handle Reload, cancellation/write-failure retention, and aborting a
  staged stale-generation write without changing its old bytes. SHA-256 checks
  confirmed the prior server file unchanged; after New saved through a distinct
  new handle, the disconnected old handle's bytes also remained identical. The real
  `showSaveFilePicker` was invoked in an active user gesture, but headless
  Chromium returned native `AbortError`: accepting an OS Save dialog remains
  unverified. OPFS proves real handle I/O, not picker security or OS acceptance;
  no Safari/Firefox, physical IME, or cross-engine certification is claimed.
- **Action-row UI verified (2026-11-02):** one actual Chromium 150 batch at
  1280×800 and 375×667 measured equal 167px / 151.5px columns, 44px heights,
  an 8px gap and matching menu inner edges. Native forward Tab moved from
  initially focused Open to New; square frames, distinct icons and acid/ink
  New hover passed. Advanced-path and Reload controls retained their existing
  sizing. This layout-only proof does not certify native dialogs, persistence,
  other engines or mobile interaction.

### Unsaved canvas filename

- **Status:** implemented as explicitly requested session-only naming, without
  changing native milestone ordering or approving proposed readiness scope.
- **Contract:** a compact document-menu Rename form changes only a pathless,
  revisionless New/downloaded-copy filename, preserving graph, JSON metadata,
  dirty state and history. Generation and pending-save guards reject stale or
  racing submissions. Opened copies, server files and browser handles cannot be
  renamed here. First native Save suggests the current name but adopts the actual
  chosen handle name only after writing; unbacked copies keep downloading under
  their current name without acquiring a handle.
- **Verified (2026-11-02):** final `mix check` passed (32 Node and 80 ExUnit
  tests). Actual Chromium form Enter updated header/tab/help/tooltip; two actual
  downloads used successive normalized names with identical v1 bytes and no
  title/name metadata. The previous server file's SHA-256 stayed unchanged.
  An actual opened downloaded copy hid Rename; native Open → Tab → New retained
  keyboard order. Max-length names fit the menu at 375×667 and 1280×800 after
  scoped filename-help wrapping.
- **Handle proof and limits:** real OPFS writes exercised matching/different
  chosen names and successful browser-file promotion with active user gestures.
  Picker cancellation preserved the suggested session name. The original native
  Save picker was invoked with active user activation but returned headless
  `AbortError`; accepting an OS dialog remains unverified. OPFS is real handle
  I/O, not OS-picker proof; masked fallback does not certify Safari/Firefox.


### Embedded text attachments

- **Status:** implemented as explicitly requested text-based embeds. Native work
  remains the final milestone; no new dependencies, external assets or live-file
  linking are introduced.
- **Contract:** [Text attachments](README.md#text-attachments) import one UTF-8
  file into a normal connectable card via one native add/history action.
  [Optional shape metadata](README.md#embedded-attachment-metadata) preserves exact
  source text outside the ordinary caption; 256 KiB/file and 1 MiB aggregate
  include duplicates. Read-only previews show literal source, including Markdown;
  Download attachment retrieves the embedded snapshot, never the original file.
  Generation guards, import flushes, clean read/download state and existing
  source-specific save/copy behavior remain intact.
- **Verified:** final `mix check` passed (114 ExUnit, 74 Node tests), including
  dismissal-focus polish. Real temporary saved JSON, native undo/redo, save-copy/reopen, metadata,
  quota refusal and stale/readonly commands are covered. Actual Chromium file
  selection and drop preserved 195-byte Markdown and a maximum 262,144-byte UTF-8
  attachment; preview/download and saved/reopened bytes matched. Physical
  double-click exposed pointer-capture retargeting; native hit-testing fixed it,
  with a deterministic regression and passing repeated browser interaction.
  Enter/F2, native Escape/focus, C binding and moved endpoints worked. Binary and
  over-limit refusal retained nodes/edges/clean state. At 375×667 the menu and
  source dialog fit, with 44px actions and no horizontal overflow.
- **Limits:** Chromium proof only, not other engines, assistive technology,
  physical OS file dialogs or mobile interaction. Download-manager completion is
  unobservable. The existing delayed native keyboard nudge can still land after
  an immediate Save; no attachment change attempts to fix that separate behavior.

### Floating Style inspector

- **Status:** implemented as the approved inspector redesign, retaining the
  existing stack, style commands, history and version-1 contract.
- **Behavior:** the bottom Style trigger opens a stable upper-right floating
  inspector below Save, not a sidebar or selection-following toolbar. Appearance
  and Text group current values; named color palettes open on demand. Controls
  intersect selected object capabilities, mixed values are explicit, inherited
  typography is read without authoring defaults, and mixed object/connection
  selections edit objects only. S opens; palette Escape precedes panel Escape;
  Close/Escape returns to Style. Same-selection patches retain native controls.
- **Proof:** `mix check` passed (114 ExUnit, 83 Node tests). Actual Chromium
  exercised shape/text/line/connector/mixed/locked states, selection focus,
  mouse versus keyboard opening, palette keys and staged Escape. Opening and
  selection changes retained clean state and unchanged temporary source bytes.
  Style change → undo/redo → Save/reopen retained geometry and unknown metadata;
  a mixed object/connection edit left connection data unchanged. Inspector fit
  was checked at 1280×800, 375×667 and 1280×480, clear of header and dock, with
  bounded scrolling and no horizontal overflow.
- **Limits:** native select DOM identity/focus and selected-value edits passed,
  but automated keyboard default selection did not work even in a bare native
  select control; OS popup keyboard behavior is not certified. Chromium layout
  checks are not other-engine, assistive-technology or mobile interaction proof.

### Zen brainstorming view

- **Status:** implemented as explicitly requested session-only canvas/drawing
  focus mode. No dependencies, document-format, fullscreen or autosave changes.
- **Contract:** Document-menu Zen mode or canvas-scoped Shift+Z keeps all drawing
  tools, Exit Zen and save/draft status while hiding file/style/rail/credit
  chrome. Errors, conflicts and recovery remain visible. Transitions retain the
  same board, selection/view, active tools, pending drafts/previews and history.
  Native editors/modes/overlays consume Escape before Zen exits. Explicit
  Style/help/Open reveals normal UI; ordinary Save works without leaving Zen.
- **Proof:** final `mix check` passed (114 ExUnit, 99 Node tests).
  Actual Chromium menu/Shift+Z toggles retained selection/tool/view/root and
  source bytes. Keyboard drawing and adjacent thoughts, undo/redo and real disk
  Save worked while Zen remained active. G/C/N previews and draft content/focus
  survived toggles; Shift+Z stayed text in drafts. Native text Escape cancelled
  first, then exited Zen. S/? revealed controls; Tab reached only visible
  controls. A real external-file conflict stayed visible with reachable
  recovery actions and no overwrite. Desktop and 375×667 layouts retained eight
  centered tools, visible exit/status and no hidden-control focus.
- **Limits:** Chromium proof only; narrow layouts are not mobile interaction,
  other-engine or screen-reader certification. Existing source-specific saving,
  download confirmation and interruption/recovery limits remain unchanged.

## Readiness additions — only explicitly adopted work is approved

Save a copy preservation is adopted; remaining proposed additions below require
approval. Any adopted non-native additions precede the final native milestone.

### 1. Preserve edits when the original cannot be saved

- [x] **Approved outcome (2026-11-02):** save a separate JSON preservation copy
      from any source mode without discarding edits or overwriting the original.
- **Implemented:** explicit **Save a copy** in the document menu and source/error
  warnings always starts a browser download with a distinct suggested filename.
  Flush valid text/geometry/thought drafts and validate version-1 bytes first;
  invalid drafts retain their text and refuse copying. Preserve source identity,
  baseline/revision, dirty/conflict state, unresolved original errors, history,
  and generation. No source check/write, native picker, or Save As reassignment.
  Downloads do not confirm disk persistence or observable download completion.
- **Acceptance:** edit a temporary canvas, change/remove its source externally
  or deny writing, then preserve elsewhere. Inspect the new JSON for the latest
  graph, pending text, and metadata; reopen it. Original bytes remain untouched,
  and the original source/conflict/dirty state stays truthful. Cancel/failure
  retain edits. A downloaded copy must not imply confirmed original-file
  persistence. No automatic merge or silent source reassignment.
- **Verified:** `mix check` passed (90 ExUnit, 40 Node tests). Actual Chromium 150
  on macOS: refused ordinary Save after an external edit, active text flushed
  into a real downloaded v1 JSON copy, current typography/metadata/bindings retained,
  original external bytes unchanged, connected server-file identity and dirty/conflict
  retained. Native Tab Open → New → Save a copy and Enter initiated a real download.
  A valid active adjacent-thought draft added exactly one node before downloading;
  Undo/Redo proved a single add with no copy history entry. A 2,001-grapheme draft
  refused copying with no download, unchanged node/edit counts and intact input.
  Geometry preview width 200 → 201 survived menu entry and appeared in downloaded
  JSON as one undoable change, including direct conflict-warning Copy. Escape
  cancelled preview before closing the menu. Deleting the source still allowed a
  preservation download without recreating it; an actual downloaded file reopened
  with text/geometry/font/binding intact. A clean renamed untitled copy remained
  untitled and clean. Desktop and 375×667 menu/warning controls fit without message
  occlusion; native Escape returned focus to the menu toggle.
- **Handle/fallback proof and limits:** a real OPFS handle with controlled denied
  permissions refused ordinary Save; copying downloaded current JSON without
  touching the handle, then a granted ordinary Save still wrote that original
  handle. Actual file-input fallback selection exercised both ordinary Save copy
  and explicit Save a copy downloads with retained dirty/source state. Picker
  hooks, controlled permissions and masked APIs prove these Chromium paths, not
  OS permission/picker behavior or Safari/Firefox/Edge compatibility. Browser
  download-manager cancellation/completion is unobservable; screen-reader and
  cross-engine certification were not exercised.

### 2. Start and keep a first personal document safely

- [ ] **Proposed outcome:** the intended first-time user can install/launch,
      create their own board, and choose where to keep it without editing the
      welcome source accidentally or confusing a browser filename with a server
      path.
- **Evidence:** startup still opens editable `examples/welcome.json`. The document
  menu now includes New canvas: a pathless in-memory board whose first Save uses
  a native Save picker when supported, or an honest Save copy download otherwise.
  Explicit server-path Create remains under Advanced: server file path.
  This implemented workflow does not complete or approve the broader proposed
  audience/setup/first-personal-document journey gate.
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
  not OS-dialog automation. Connected-arrow appearance and the final independent
  native editor remain separate milestones.
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
  recovery promise. Save a copy provides explicit preservation; download initiation
  alone is not completed persistence or proof of interruption recovery.
- Record web-slice, native-workflow, and overall product acceptance separately.
  Proposed gates become release requirements only after explicit scope approval.
  If adopted, non-native validation precedes the final native milestone;
  native-workflow and native presentation proof apply within that milestone
  when native exists, not as prerequisites to starting it.

## Later

- [ ] **File-menu usability:** scrolling already exists (`app.css`, max-height
      and overflow-y). Improve compactness, keyboard access, and short-window
      reachability; do not merely hide the scrollbar. Promotion into readiness
      is not yet approved.
- [ ] **Code snippets:** confirmed dedicated code blocks, not only the existing
      shape Code typography; monospace text with syntax highlighting, in both
      the web editor and the planned independent native Mac editor.
      Web code snippets precede the final native milestone; native code snippets
      remain part of that final milestone, not a prerequisite to starting it.
      Enter inserts a newline; Tab/ShiftTab indent/unindent; Escape finishes
      editing. Disable canvas commands while editing a snippet.
      Paste only inside an open snippet editor; canvas paste must not
      automatically create a code block. No code execution is implied.
      Support common programming languages including Elixir; automatically detect
      the language with manual override. Agree the exact inventory before implementation.
      Provide a dedicated Copy code action copying literal text and whitespace.
      Preserve the local JSON/version-1 compatibility policy; discuss format
      changes before implementation. No schema or dependency choice is approved,
      and this scope does not require full web/native parity.
      **Proposed acceptance:** in each implementation when available, type and
      paste a multiline snippet inside its editor; exercise language autodetection
      and manual override; verify Copy code preserves literal text and whitespace.
      Preserve indentation; exercise the agreed controls and keyboard isolation;
      edit, undo/redo, and save/reopen with unrelated content intact.

Promote optional work only as ranked hypotheses grounded in observed session
friction.

## Needs decision

- [x] **Connected-arrow appearance:** approved (2026-11-02): color, width 1/2/4
      and dash in optional `edge.data.connector_style`, keeping version 1 and
      existing target marker semantics. See [edge contract](README.md#edges).
      No standalone arrowhead mapping or new attachment behavior is approved.
- [ ] **Audience and delivery:** personal/developer setup versus broader users;
      agree first-install/launch expectations and native install/distribution
      needs. Do not presume signing, notarization, an app store, or a packaging
      toolchain.
- [ ] **Restart/local recovery:** agree supported interruption cases, loss
      warnings, and whether recovery beyond explicit save/preservation copies is
      required. Decide storage/lifetime/privacy implications before adding any
      local draft mechanism.
- [ ] **Proposed readiness:** decide which additions become scope and their
      placement before the final native milestone, and the representative
      workload/user session. This sequencing does not approve the additions.
- [ ] **Favicon (low priority):** logo/favicon assets and layout references
      exist; confirm a concrete branding gap before changing assets or marking
      work complete.

## Resolved design note

- **“Do we need nodes to connect an arrow/line so it follows when moved?”**
  Existing bound arrows already follow their endpoint shapes
  ([current behavior](README.md#edit)). Keep plain Line free-standing, including
  when drawn between shapes; do not turn the old question into attached-Line
  work.

## Final milestone: independent native macOS editor

Start native work only after the remaining non-native work and non-native scope
decisions, including web code snippets and any adopted readiness work, are complete.
Native code snippets remain included here under the shared Code snippets
requirements and acceptance in Later; they are not a precondition to this milestone.

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
- **Repository organization (prepared 2026-11-03):** one repository, the web app
  left at the root, a separate `macos/` project location, and shared version-1
  fixtures in `shared/fixtures/v1/`; independent builds and runtimes. The
  existing document fixture was moved byte-for-byte and web consumers migrated.
  See [repository layout](README.md#repository-layout). No native app or build
  configuration exists yet. Swift with AppKit, SwiftUI, and Core Graphics remains
  a candidate, not an approved architecture.
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

- [x] Prepare repository organization for the native project without moving
      the working web app or changing its commands.
- [ ] Resolve native decisions before project creation/implementation as
      applicable.
- [ ] Agree compatibility fixtures and prove round-trips before editable saves.
- [ ] Deliver the agreed native workflow/history and failure/conflict proof.
      New/create/connect behavior remains unresolved, not implied by “editor.”
- [ ] Meet the PNG/Keynote gate using actual exported files.
- [ ] Supply audience-appropriate setup/launch/check instructions and prove
      runtime independence; decide install/distribution needs before release
      infrastructure.

### Native decisions

- [ ] **Native authoring:** recommend a minimal New → draw/text → connect
      workflow for brainstorming, but decide creation versus existing-document
      editing explicitly. If edit-only, identify where starting boards come from
      and describe that boundary honestly; neither decision implies full web
      parity.
- [x] **Native repository organization:** web at root, `macos/` for native code,
      `shared/fixtures/v1/` for shared JSON; independent builds and runtimes.
- [ ] **Native technology and compatibility:** decide minimum macOS, stack and
      UI/rendering responsibilities, supported content and editing scope,
      additional shared fixtures, and independent build/check instructions.
      Swift/AppKit/SwiftUI/Core Graphics remains a proposal, not approval.
- [ ] **PNG output:** agree default dimensions/scale and maximum output size;
      retain transparency, font readiness, clipping, zoom/DPR, and Keynote proof
      above.

## Done

- [x] redesign with acid theme
- [x] canvas styling using acid theme
- [x] canvas-focused zoom shortcuts; browser page zoom outside canvas focus
- [x] add a line
- [x] ability to do a loop with arrow/line
- [x] Do rotation, the drawing item is rotating, but the guide nodes stay still.
      I think it's a bug
- [x] Load file using os's native load file
- [x] **Triangle attachment gap (2026-11-02):** named and automatic connection
      ends meet the actual triangle outline, including rotated non-square shapes
      and live geometry previews; side binding names and free-standing Lines stay
      unchanged. Source-derived rectangular-midpoint gap confirmed the root cause.
      Full Mix (64), Node (27), syntax, format, and existing asset build passed.
      Independent actual Chromium pointer create/move/rotate/resize/cancel,
      pan/zoom, reconnect, Save/reopen proof measured maximum endpoint-to-outline
      residual **0.058px**; self-loop exterior routes, styles/markers, standalone
      endpoints, omitted shape fields, and metadata were retained. The first
      mixed-node load's initialization guard defect was fixed and regression-covered.
      Limits: no Safari/Firefox/Edge, screen-reader, physical IME, or native-picker
      certification; no visual control redesign.
