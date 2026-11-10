# MVP plan

Unchecked work is not implemented behavior. Current web editing and the native
macOS canvas editor (including `NSDocument` JSON persistence, coalesced autosave,
conflict handling, crash/draft recovery, and Keynote PNG export) are implemented;
on 2026-11-10, native v2 code-snippet authoring/highlighting was explicitly
deferred to the next phase of development (existing v2 `code` nodes remain
preserved, rendered as plain text, and round-tripped losslessly).
The separately approved adjacent-thought task is implemented. Connected-arrow
styling's additive v1 metadata scope is now approved (details below); the native
editor remains last. Save a copy preservation is separately approved and
implemented below; other proposed readiness additions remain **unapproved scope**.
Decide their adoption and placement before the final native milestone.
Native implementation is requested; the approved command-line build route is
recorded below. Web remains at root, the independent native project belongs in
`macos/`, and both shared v1/v2 fixture baselines exist. Other proposed readiness
work remains unapproved.

## Product outcome and existing baseline

**MVP outcome:** turn an idea into a useful spatial diagram, preserve it as an
ordinary local JSON document, return to it safely, and use it in a presentation.
Completing web-editing slices alone is web-slice completion, not product-MVP
proof. Choose the primary job: recommend individual brainstorming/systems
diagrams → presentation, not four equal feature sets. Facilitated use can be
single-driver, not multiplayer. Agree the intended user and which editor
completes this journey.

Keep the [version-1 contract](README.md#document-format-version-1) for existing
files and the implemented [version-2 contract](shared/CODE_SNIPPETS.md) for new
documents, the local-file-first trust boundary, and [agent policy](AGENTS.md).
No database, accounts, cloud, collaboration, automatic merging, or full native/web
parity is implied. Further format changes require approval; preserve existing v1 files.

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
- [ ] **Code snippets — web implemented; native authoring/highlighting deferred to next phase (2026-11-10):**
      dedicated code blocks, not only shape Mono typography. The web editor now
      implements the [shared v2 contract](shared/CODE_SNIPPETS.md), dedicated source
      editor, literal Copy code, language control, highlighting, Fit, keyboard
      isolation, clipboard/history, and save integration. On 2026-11-10, native
      code-snippet authoring/source editing and `HighlighterSwift` syntax
      highlighting were deferred to the next phase of development; the current
      native editor preserves existing v2 `type: "code"` nodes losslessly,
      renders them in `Monaspace Neon`, enforces the 256 KiB / 1 MiB quotas, and
      supports selection, movement, resize/rotation, style inspection,
      connections, duplication, deletion, and PNG export.
      Enter inserts a newline; Tab/Shift-Tab indent/unindent; Escape finishes.
      Plain-source paste creates no block outside an open snippet editor.
      Code is neither an attachment nor a caption and is never executed.
      **Settled format/policy:** new documents use `version: 2` and explicit
      `type: "code"` nodes; existing v1 files keep saving as v1. Explicit v1→v2
      conversion downloads a separate snapshot with only the root version changed,
      leaving original source, baseline, dirty/errors, and history untouched.
      Download initiation does not prove final persistence or expose the user's
      final path. No hidden migration/downgrade; v2 stays v2 after deleting code.
      Literal UTF-8 source retains BOM, tabs, CR/LF/mixed endings and whitespace;
      other C0/C1 controls and DEL are refused. Limits are 256 KiB per source and
      1 MiB across all copies, independent of attachment quotas.
      **Settled languages/web dependencies:** Auto, Plain text, Elixir, Erlang,
      JavaScript, TypeScript, JSON, HTML, CSS, Shell, Python, SQL, Swift, Rust.
      Omitted language means Auto; unknown nonempty IDs remain retained as plain
      text. Manual choices persist; detection/tokens/themes are never metadata.
      Approved npm-managed Shiki 4.6 uses fine-grained grammars and its JavaScript
      engine; Highlight.js 11.12 provides conservative Auto detection with plain
      text fallback. This does not select a native engine or approve a web runtime
      in the native app. Shared fixtures exist at `shared/fixtures/v1/document.json`
      and `shared/fixtures/v2/document.json`.
      **Native acceptance still pending:** type/paste multiline source, exercise
      detection/manual override and literal Copy code, preserve indentation and
      keyboard isolation, and edit/undo/redo/save/reopen across both editors with
      unrelated content intact. Native engine, implementation, and workflow proof
      remain undelivered; web acceptance below does not prove native workflows.
      **Web verification:** `mix check` passes 141 ExUnit and 140 Node tests,
      formatting, warnings-as-errors compilation, JS syntax and both asset entries.
      Temporary-file smoke verifies exact source/metadata saves, external-change
      refusal and version-only copy conversion. Chromium smoke verifies menu and
      dragged creation, source/draft saves, literal clipboard, manual/Auto
      persistence, ink highlighting, invalid-draft retention, 640×480 action
      reachability, offviewport clipped-export refusal, fitted PNG pixels/alpha,
      and separate v2 download plus explicit Open without promoting the original.
      Paste was synthetic; native OS picker, real IME and other browsers remain
      unverified. These checks do not establish native Mac support.
      Activation repair additionally verifies real v2 click/drag placement,
      literal typing, Finish and saved JSON; v1 shows visible conversion/New
      guidance without arming Code. Wide/narrow Cancel and Copy retain the
      expected draft/history boundaries after fixing action-button blur ordering.
      Editor-action verification covers native fit-label/Space toggles without
      committing, literal Copy/Cancel isolation, unchecked geometry retention,
      checked source+fit as one Undo/Redo transaction, actual JSON metadata
      retention, ephemeral fit reset, and reachable 640×480 completion controls.
      Code-body movement proof uses real text/padding drags, one-step Undo/Redo,
      connected-edge remeasurement, actual saved geometry with exact source/
      metadata retained, wheel scrolling without view/dirty changes, Space pan,
      Control-wheel zoom, locked-drag refusal and Copy/edit isolation.
      Classic scrollbar tracks have Node boundary coverage only; the browser
      exposed overlay scrollbars, so no thumb/track interaction was certified.
      **End-to-end web acceptance (2026-11-04):** real Code creation, Unicode
      source/manual language, move/resize, C connection, native Undo/Redo,
      Cancel without history, clipped-export refusal, Fit, Save and reload passed
      on a disposable server-file canvas. Actual saved JSON retains exact source,
      geometry, bound edge, unknown metadata and integer 9007199254740993.
      C mode exposed a code-editor Enter interception bug, now fixed and covered.
      External-change Save flushes a valid draft but preserves external bytes;
      Save a copy contains the latest graph without clearing dirty/conflict state.
      Actual 1648×968 PNGs verify opaque/transparent output and excluded UI.
      Export-startup proof requests while highlighting is pending, then observes
      colored output identical to native Download after readiness; export now
      waits for current tokens or explicit plain-text fallback instead of racing
      the worker. Node coverage includes stale replies and generation replacement.
      This is automated Chromium/server-file acceptance, not an intended-user
      session, OS-picker/IME/cross-browser certification, or native/Keynote proof.

Promote optional work only as ranked hypotheses grounded in observed session
friction.

## Needs decision

- [x] **Connected-arrow appearance:** approved (2026-11-02): color, width 1/2/4
      and dash in optional `edge.data.connector_style`, keeping version 1 and
      existing target marker semantics. See [edge contract](README.md#edges).
      No standalone arrowhead mapping or new attachment behavior is approved.
- [x] **Native first audience (2026-11-04):** personal use first, for the author's
      brainstorming, developer diagrams, and Keynote workflow. Prove local
      build/launch; public distribution, signing/notarization, updates, and an app
      store are not first-release requirements. Decide them before wider release.
      The broader product-MVP audience and readiness scope remain unresolved.
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

The web code-snippet prerequisite is implemented. The native macOS editor now
implements shape/text/line/connection/adjacent-thought authoring, style inspection,
transparent Keynote PNG export, and `NSDocument`-backed JSON persistence, coalesced
autosave, external-change conflict handling, and draft/crash recovery. On
2026-11-10, native code-snippet authoring/highlighting was deferred to the next
phase of development; overall milestone acceptance and any adopted readiness
gates remain below.

The [native implementation specification](macos/SPEC.md) was drafted on
2026-11-04 as requested. It details interactions, autosave/recovery, compatibility,
native components, export, and acceptance proof. The architecture, macOS target,
initial content scope and PNG defaults were approved on 2026-11-05 as recorded
below, and `NSDocument` persistence, coalesced autosave, conflict handling, and
recovery were implemented and verified on 2026-11-10.
- [ ] **Outcome:** open an existing version-1 JSON canvas in an independent
      native Mac editor, select/move objects, edit text, undo/redo, save, and
      reopen in both editors; export a transparent high-resolution PNG suitable
      for Keynote.
- **Purpose:** personal structured brainstorming, developer systems diagrams,
  facilitated sessions, and illustrations for presentations.
- **Committed direction:** native UI follows Apple Human Interface Guidelines,
  not Neo-Acid. No wrapper, webview, Phoenix server, or BEAM runtime in the Mac
  app. Share the [v1 contract](README.md#document-format-version-1) and implemented
  [v2 code-node contract](shared/CODE_SNIPPETS.md), not a runtime.
  Preserve v1 compatibility, authored geometry, semantic font roles, and named
  colors. Native font/palette resolution may differ; pixel identity is not required.
- **Repository organization (prepared 2026-11-03):** one repository, the web app
  left at the root, a separate `macos/` project location, and versioned fixtures
  in `shared/fixtures/v1/` and `shared/fixtures/v2/`; independent builds and runtimes.
  The existing v1 fixture was moved byte-for-byte and web consumers migrated.
  See [repository layout](README.md#repository-layout). A Swift Package and
  command-line build now provide a read-only viewer. Swift/AppKit with Core Graphics
  target macOS 27. On 2026-11-05, Swift Package plus command-line `.app` bundling
  replaced the earlier Xcode-project choice; AppKit inspectors replaced SwiftUI.
- **Before editable saves:** establish compatibility fixtures and round-trip proof.
  Resolve remaining recovery, native file UX, font mappings, highlighter and
  shortcuts before the corresponding features. Approved content and PNG defaults
  do not imply full web feature parity.
- **Compatibility gate:** agree fixtures covering supported shapes/text,
  standalone lines, connections/self-loops, rotations, locks, and metadata.
  Unsupported content must be identified before editing: reject it clearly or
  open read-only without loss; never silently omit it or permit a lossy save.
- **Round-trip proof:** on temporary fixture copies, open → render → select/move
  → edit text → undo/redo → autosave → reopen in web and native. Compare actual
  JSON: stable IDs, node stacking order, bindings and handles, styles, unknown
  metadata, named colors/font roles, and unedited authored geometry survive;
  only intended edits differ. Plain Line remains free-standing. Renderer
  font/theme choices must not dirty files.
- **Mac workflow proof:** native menus, keyboard commands, file dialogs, and
  window lifecycle work together. Exercise autosave after completed edits,
  explicit Save, untitled-file destination choice and recovery, close/quit/open
  with pending or failed writes, cancellation, invalid files, and external-change
  conflicts. Retain edits and the original source on refusal/failure; never
  silently overwrite an external change. Use atomic replacement with conflict
  checks; document remaining race/durability limits rather than claiming
  filesystem locking. Autosave must not clear or split undo history.
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
- [x] Write the native implementation specification, separating approved direction
      from proposed behavior and executable acceptance requirements.
- [ ] Resolve native decisions before project creation/implementation as
      applicable (native code-snippet authoring/highlighting deferred to next phase 2026-11-10).
- [x] Agree compatibility fixtures and prove round-trips before editable saves.
- [ ] Deliver the agreed native creation/editing workflow, keyboard and pointer
      interactions, history, autosave, and failure/conflict proof.
- [x] Meet the PNG/Keynote gate using actual exported files.
- [ ] Supply audience-appropriate setup/launch/check instructions and prove
      runtime independence; decide install/distribution needs before release
      infrastructure.

### Native decisions

- [x] **Native authoring (2026-11-04):** create and edit canvases, not only edit
      web-created files. The first complete workflow starts with a blank canvas:
      New → add shapes/text → connect/rearrange → autosave JSON → export for Keynote.
      The native app must be useful without launching the web app. Initial content
      coverage is approved below; this does not approve full web parity or every
      proposed feature.
- [x] **Native interaction (2026-11-04):** keyboard-first, pointer-complete.
      Prioritize rapid thought entry, adjacent thoughts, and keyboard connections;
      retain direct manipulation, discoverable controls, native text editing,
      and standard Mac commands. Exact shortcuts remain to be designed.
- [x] **Native persistence direction (2026-11-04):** autosave to the document,
      not an explicit-Save-only workflow. Connected JSON files update
      automatically; untitled documents need recovery before a source is chosen.
      Explicit Save remains available. This is native-only; the web app's
      persistence contract is unchanged.
- [x] **Native recovery scope and timing (2026-11-05):** recover committed work
      and acknowledged active text drafts using native untitled recovery plus
      private app-owned storage only for uncovered state. Retain until saved
      elsewhere or explicitly discarded, with no silent expiry. Request autosave
      and recovery writes after 5 seconds quiet or within 30 seconds of continuous
      changes; these are request targets, not durability guarantees. Incomplete
      IME composition and changes after the last recovery write can be lost.
- [x] **Native conflict, restoration and close choices (2026-11-05):** pause
      autosave on an external change, retain local edits/history, and offer Save
      As, confirmed Reload, or Keep Editing with autosave paused; no force overwrite.
      Ask before restoring recovery; if the source changed, restore as a separate
      untitled document. Close/quit finishes valid editors and awaits writes;
      unresolved work offers return to editing, retain recoverable work, or
      explicit discard. Cancel leaves the window open.
- [x] **Remaining native recovery/file policy (verified 2026-11-10):** `CanvasNativeDocument`
      (`NSDocument`) uses `autosavesInPlace` and `autosavesDrafts` (`autosavedContentsFileURL`)
      with SHA-256 byte-fingerprint verification inside `writeSafely`/`write`, paired with
      private `0600` `CanvasRecoveryEnvelope` files in `Application Support/local.elixircanvas.native/Recovery/`
      storing only uncovered metadata and active non-marked inline text drafts without
      duplicating the committed JSON snapshot. Verified across launch restoration,
      external conflicts, read-only/write failures, and multi-window close/quit guards.
- [x] **Native repository organization:** web at root, `macos/` for native code,
      versioned shared JSON in `shared/fixtures/`; independent builds and runtimes.
- [x] **Native foundation and initial content (2026-11-05):** Swift; AppKit
      document/window lifecycle, custom canvas and inspectors; Core
      Graphics/native text layout shared with PNG; Swift Package and command-line
      `.app` bundling under `macos/`, minimum macOS 27. Author shapes/text,
      standalone lines/arrows, connections and v2 code under
      [SPEC section 5](macos/SPEC.md#5-proposed-compatibility-and-editing-surface).
      Existing attachments support preservation, preview, export, duplication and
      removal; new attachment import is outside the initial scope. The package,
      bundling step and highlighter candidate below are approved; other new
      third-party dependencies require approval.
- [x] **Native highlighter candidate (2026-11-05):** approved HighlighterSwift,
      an MIT-licensed Swift wrapper around BSD-licensed Highlight.js using system
      JavaScriptCore, not a webview. A temporary Swift Package was built for macOS
      27, bundled with its resources and launched via Launch Services. One sample
      for each of 12 required language identifiers returned exact UTF-8 text and
      multiple colors (HTML→xml, Shell→bash); leading/trailing whitespace, BOM,
      mixed line endings, empty and markup-like samples also retained exact bytes.
      Auto returned exact sample text, but detection accuracy, full safety, pinned
      version and native editor/export integration remain unproven. No dependency
      is installed yet.
- [ ] **Native compatibility/toolchain proof:** provide actual native build/check
      instructions, extend the agreed content fixtures and prove non-lossy
      rendering/round-trips before editable saves. A temporary Swift Package built
      against macOS 27, manually bundled and launched via `open -n -W`, reported
      an AppKit window visible on this machine. The linker warned of two missing
      Command Line Tools search paths; build and launch succeeded. This does not
      prove the editor, document handling, signing, distribution or native tests.
      A minimal SwiftUI `@State` inspector fails to compile with Command Line
      Tools because `SwiftUIMacros.StateMacro` is unavailable. A temporary AppKit
      inspector launched and handled an injected native mouse event: the checkbox,
      model and label agreed; a subsequent model update changed both controls.
      External automation was denied Accessibility permission, so this is not
      physical-pointer or accessibility-interaction proof.
      The native viewer opens temporary v1/v2 fixtures in separate windows without
      changing source bytes. Native validation retained exact original bytes; the
      web app saved and reopened copies, which native validation accepted again.
      Offscreen AppKit bitmap inspection covered both fixtures; direct window
      capture failed, so the actual windows were not visually captured.
      Native contract checks cover shared fixtures and selected refusal/quota cases.
      The native app uses approximate routes and plain-text code rendering (native code
      creation/editing and syntax highlighting remain pending). It supports `NSDocument`-backed
      blank v2 New, v1/v2 Open (activating the existing window when reopening an already-open
      file), explicit Save (`⌘S`), Save As (`⇧⌘S`), explicit v1→v2 copy export
      (`File → Save Version 2 Copy…`), confirmed Reload from Disk, coalesced 5s-quiet /
      30s-continuous autosave, external-change conflict pause, `NSDocument` draft autosaving
      plus private recovery envelopes for active inline text drafts, launch recovery restoration,
      multi-window close/quit guards, shape/text and standalone line/arrow insertion,
      adjacent thoughts (`N` → cardinal direction → inline draft with rotated ray-blocker
      avoidance and measured growth), connections (creation, labels and endpoint/side
      reconnection), object/connection selection, selection-preserving Tab traversal,
      Space tap selection toggle and Space-drag panning, marquee and Shift-click/⌘A
      multi-selection, pointer/arrow movement (with pointer drags isolated as view previews
      until `mouseUp`), resize/rotation and line endpoint editing, duplication, deletion,
      front/back stacking, lock/unlock, object/connection/canvas style inspection/editing
      (`S` / Edit → Style…), caption editing with measured box growth, read-only
      attachment source preview/copy, canvas zoom/fit (`+`/`-`, `⇧1`, `⇧0`/`⌘0`),
      transparent PNG export (`File → Export PNG…`, `⇧⌘E`) and Undo/Redo.
      Shared v1/v2 compatibility fixtures cover five shape kinds, free line,
      rotation/locks, all edge paths/markers (`bezier`, `smooth`, `step`, `straight`,
      `arrow`, `dot`, `none`), self-loop and automatic/named handles, `animated`/`dash`
      precedence, non-object `connector_style` collision, Unicode and empty `text/plain`
      attachments, unknown metadata/64-bit integers, and literal code with mixed line
      endings/language variants. Native `CanvasDocument.encode` / `CanvasSession.encodedData`
      and web `Document` tests prove non-lossy temporary-file round-trips, independent
      1 MiB attachment/code budgets, explicit v1→v2 copy conversion, and cross-editor
      `Native → Web → Native` edits and undo restoration while keeping the native UI
      session-only until persistence/autosave is wired.
      Native interaction checks create real AppKit mouse/key events: pointer drag
      commits one move, Command actions call the active canvas history, Undo/Redo
      restore exact geometry, Shift-Arrow moves 10 units, a locked node remains
      unchanged, connected edges remeasure in memory, and original JSON bytes stay
      identical. A failed nil-target responder-chain Undo check was replaced with
      explicit app-delegate routing to the active window's canvas.
      Native shape-caption and `T` text editing now use an inline on-canvas
      `NSTextView`: double-click or Return opens it; Return/Command-Return commits,
      Shift-Return inserts a newline, and Escape discards.
      Native checks exercise literal multiline Unicode, locked refusal, draft
      isolation, metadata/absent-text restoration, Undo/Redo, no-op redo retention,
      2,000-grapheme acceptance and over-limit refusal with draft intact.
      Caption commits grow shape height along local axes (keeping the top anchor
      fixed on rotated shapes, measured with bundled Neo-Acid and Amatic SC faces
      plus CoreText system cascade fallback) as one atomic transaction; code
      editing and physical IME/accessibility proof remain open.
      File New now creates separate blank v2 sessions; Insert offers rectangles,
      ellipses, diamonds, triangles and text at the viewport center (canvas-only
      R/O/D/I/T). New `T` text remains an inline on-canvas draft until committed.
      Native checks cover scrolled viewport placement, valid authored graphs,
      refused nonfinite placement, cancellation/empty/invalid text without nodes,
      original metadata/source retention, stable IDs/stacking on redo and mixed
      insertion/movement history. A temporary executable using the actual app
      delegate and release libraries exercised File New, Insert, Undo/Redo, text
      commit, canvas focus and two independent untitled windows.
      Native C / Insert Connection opens a source/target and side-picker sheet.
      Automatic sides remain omitted; self-loops need distinct named sides.
      Native checks cover missing endpoints, invalid/valid self-loops, retained
      drafts, one-object defaults, cancellation, stable IDs/order, v1 metadata and
      source-byte retention. Bitmap checks verify connection appearance/removal,
      rerouting after endpoint movement and exterior-route visibility without
      camera movement. A temporary actual-app-delegate smoke exercised New →
      Insert → pointer arrange → Connection → mixed menu Undo/Redo and Escape.
      That smoke first exposed event-grouped insertions merging; per-canvas
      explicit transaction groups fixed it, with back-to-back command regressions
      and removal of run-loop timing from the history checks.
      Screen-capture permission is unavailable; an offscreen sheet bitmap omitted
      composited native control labels, so it is not complete window visual proof.
      Native unlocked shapes/code now expose eight resize handles and rotation;
      G / Edit Geometry enables Tab/Shift-Tab, local-axis arrow previews,
      Return commit and Escape cancel. Shift steps are 10 units / 15 degrees.
      Opposite anchors remain fixed during rotated resizing; crossing clamps
      instead of flipping. Standalone lines and arrows (`L` / `A` and Insert menu)
      remain free-standing (refused as bound-connection endpoints) and use
      two-endpoint editing (`start` / `end`) with 12-unit padded boxes rather than
      box scaling.
      Native checks cover pointer/keyboard preview isolation, rotated pointer
      resizing, full-circle rotation, standalone line/arrow insertion, pointer and
      keyboard endpoint editing (including reversed/horizontal segments), no-op/cancel
      redo retention, exact metadata and omitted-rotation restoration, locked/box-scale
      refusal, literal code retention, and bitmap connector/segment redraw/cancel
      behavior. Actual app-delegate menu and NSApp-dispatched key/pointer smoke passed;
      a custom-canvas bitmap showed all rotated handles, the active handle and rotation
      stalk without clipping.
      Geometry checks also exposed the SDK's JSONSerialization dropping leading
      U+FEFF inside strings. Native decoding now retains raw token validation,
      decodes strings with JSONDecoder and revalidates restored quotas. Regression
      checks prove BOM/line-ending/Unicode bytes, unknown string keys, large integer
      metadata and BOM-inclusive byte/grapheme limits. No format migration or saves.
      Native object and connection lifecycle commands now support pointer and
      Tab/Shift-Tab selection of objects and connections (including label pills),
      Cobalt connection selection highlights, Delete/Forward Delete of connections
      and unlocked objects (atomically removing and restoring incident connections
      at their original indices), Duplicate (`⌘D`) at `(+24, +24)` with fresh IDs,
      preserved `data` and 1 MiB attachment/code quota enforcement, Bring to Front
      / Send to Back (`⌘⇧]` / `⌘⇧[`) with overlap bitmap proof and no-op redo
      preservation, and undoable Lock / Unlock (`⌘L`) preserving omitted versus
      explicit `locked` fields.
      Native AppKit Style inspector (`S` and **Edit → Style…**) now exposes
      capability-specific controls for shapes (`fill`, `stroke`, `width`, `dash`,
      `radius` on rectangles, `font`, `size`, `align`), text (`fill`, `font`,
      `size`, `align`), standalone lines (`stroke`, `width`, `dash`, `arrow`),
      code blocks (`fill`, `stroke`, `width`, `dash`, `radius`, `size`),
      connections (`edge.data.connector_style` `stroke`, `width`, `dash` plus
      top-level `path` and `marker`, with `animated` retention and visible
      non-object `connector_style` collision refusal), and the canvas when
      nothing is selected (`paper.background`, `paper.grid` and `appearance.font`,
      preserving unknown `paper`/`appearance` metadata). Selected connections also
      support label editing and endpoint/side reconnection via Return/double-click/C,
      and attachment cards open a read-only literal UTF-8 source preview sheet with
      exact BOM-preserving clipboard copy. Observation never materializes
      omitted defaults; same-selection patches preserve native control identity and
      focus, and staged Escape cancels
      geometry previews before closing Style and before clearing selection.
      Native adjacent thoughts (`N` and **Insert → Adjacent Thought**) and
      viewport/selection controls now support `N` → cardinal arrow (`↑`/`→`/`↓`/`←`)
      → inline draft with a dedicated draft `UndoManager`, 160×96-minimum upright
      rectangle placement 48 world units beyond rotated source bounds, multi-pass
      rotated ray-blocker skipping (rechecked on live multiline height growth),
      2,000-grapheme boundary enforcement without truncation, blank/whitespace
      thought commits, chained `N` from the newly created thought, single-step
      Undo/Redo restoring source focus, selection-preserving Tab/Shift-Tab
      traversal with Space tap toggle, Space-hold pointer panning, marquee and
      Shift-click/`⌘A` multi-selection with grouped movement, and canvas zoom/fit
      (`+`/`-`, `⇧1`, `⇧0`/`⌘0`, trackpad magnification, and **View** menu commands).
      Final package smoke caught an invalid bundle resource signature: direct
      execution died with signal 9, signature verification failed, and Launch
      Services refused to spawn it. The bundler now ad-hoc signs the assembled
      app and strictly verifies it. Both direct execution and `open -n` then
      produced an observed on-screen window. This is local signing/launch proof,
      not Developer ID signing, notarization or distribution certification.
      Native `NSDocument` persistence, coalesced autosave, conflict handling, and
      recovery checks (`PersistenceChecks.swift`, verified 2026-11-10) cover: blank-canvas
      authoring → valid inline text draft flush and invalid 2,001-grapheme draft refusal on
      Save → first-save promotion → intact Undo/Redo across Save → single-writer reopen of
      an already-open file; pointer-drag preview isolation (`mouseDragged` keeps
      `CanvasSession` untouched so mid-drag timers never serialize unconfirmed coordinates
      and `Escape` cancels cleanly); coalesced 5s/30s autosave, in-flight write + newer-edit
      race, Edit → in-flight save → Undo-to-baseline race (acknowledging exact written
      snapshots so disk/session divergence stays `.changesPending`), stale-generation
      `Save As` isolation, and completion-delayed-beyond-deadline guard; external writer
      modification and deletion conflicts pausing autosave with **Keep Editing**, confirmed
      **Reload from Disk** (requiring an acknowledged independent pre-reload recovery backup
      and refusing reload when recovery fails or is still in flight), and **Save As…**
      (refusing the conflicted source or hardlink aliases as a force-overwrite target);
      read-only source enforcement (disabling Save, Insert, and Edit/Undo/Redo mutations and
      ignoring pointer/keyboard mutation attempts until `Save As` promotes a writable copy),
      write-failure retention, separate recovery-error tracking, and multi-window
      cancelled-Quit preservation (separating close approval from teardown); launch recovery
      using `NSDocument` draft autosaving (`autosavedContentsFileURL`) plus lightweight
      `CanvasRecoveryEnvelope` without snapshot duplication across untitled + active text
      draft, unchanged connected source, changed connected source (restored as separate
      Untitled), and corrupt recovery discard; explicit v1→v2 copy conversion refusing
      same-file/hardlink overwrite while preserving v1 in-place saves; real `NSSavePanel`
      modal invocation and cancellation; multi-process `SIGKILL` crash → fresh OS process
      relaunch recovery restoring both committed nodes and active inline text drafts;
      bundle-isolated runtime independence proof (`otool -L` confirming only macOS system
      frameworks/libs, `strings` confirming no `#filePath` `Sources/CanvasUI/PNGExport.swift`
      source-tree fallback in `CanvasApp`, Phoenix stopped, minimal `PATH="/usr/bin:/bin:/usr/sbin:/sbin"`,
      `macos/Resources/Fonts` hidden on disk, the copied `Elixir Canvas.app/Contents/MacOS/CanvasApp`
      launching and closing cleanly on a temporary document in `/tmp`, and `CanvasChecks --verify-standalone-workflow`
      placed inside that copied `.app` bundle registering all 6 fonts from
      `.app/Contents/Resources/Fonts/` and driving `New → shapes/text/adjacent thought/connection →
      pointer rearrange + Undo/Redo → Save → coalesced autosave → close/reopen → 2048×830
      transparent PNG export`, then validated by `ElixirCanvas.Document.open/1`); and
      `Native → Web → Native` cross-editor round-trips on temporary v1/v2 compatibility
      copies. External Accessibility automation permission is denied on this machine, so
      physical OS Save-panel button clicking and install/distribution decisions remain open.
- [x] **PNG output defaults and native/Keynote proof (2026-11-05, verified 2026-11-10):**
      2,048-pixel longest side, proportional other dimension, configurable output
      (longest side or exact dimensions with transparent letterboxing), 32 world-unit
      padding; caps of 8,192 pixels per side and 16,777,216 pixels total. Bundled
      Neo-Acid (`Mona Sans` 400/700, `Unbounded` 800, `Monaspace Neon` 400/700) and
      `Amatic SC` 700 font faces in `macos/Resources/Fonts/` register via CoreText
      with system cascade fallback for CJK/emoji and share layout/rendering between
      `CanvasView` and offscreen sRGB PNG export. `CanvasChecks` verifies font
      resolution/fallback, empty-canvas and cap refusals, 32-unit padded bounds
      around rotated shapes/self-loops/labels/markers, true alpha without paper/grid/
      selection/inspector chrome, byte-identical output across zoom/pan/selection,
      exact-dimension letterboxing, valid draft/preview flushing, invalid 2,001-grapheme
      draft refusal, and the interactive **File → Export PNG…** (`⇧⌘E`) sheet.
      Actual exported PNGs placed onto `/Applications/Keynote.app` `Basic White` and
      `Basic Black` slides and exported via Keynote as slide images confirmed
      intact `(1.00, 1.00, 1.00)` and `(0.00, 0.00, 0.00)` slide backgrounds with
      unclipped diagram content.

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
