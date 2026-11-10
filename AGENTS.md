# Agent context

## Product and trust boundary

Elixir Canvas is a local-file-first spatial thinking canvas built with Elixir,
Phoenix LiveView, and Hakushi. JSON files are the actual documents, not database
exports. There is no database in the current application.

The server is local and unauthenticated, with access to the machine's filesystem;
it is not a hosted multi-user service. Keep this trust boundary explicit.
Databases, accounts, cloud storage, and multiplayer are outside the current scope
unless requested, not permanently prohibited directions.

An independent native Mac editor is in progress, sharing JSON contracts rather
than the web runtime. `macos/` currently provides `NSDocument`-backed v2 New and
v1/v2 Open, explicit Save (`⌘S`), Save As (`⇧⌘S`), v1→v2 copy export (`File → Save Version 2 Copy…`),
confirmed Reload from Disk, coalesced 5s-quiet / 30s-continuous autosave with
SHA-256 byte-fingerprint conflict detection inside `NSDocument`'s coordinated
safe-save path, `NSDocument` draft autosaving (`autosavedContentsFileURL`) paired
with private app-owned recovery envelopes for uncovered state and active inline
text drafts, launch recovery restoration, multi-window close/quit guards,
shape/text and standalone line/arrow insertion, adjacent thoughts (`N` → cardinal
direction → inline draft with rotated ray-blocker avoidance and live measured growth),
connections (with labels and reconnection), object/connection selection,
selection-preserving Tab traversal, Space tap selection toggle and Space-drag
viewport panning, marquee and Shift-click/⌘A multi-selection, movement, box
resize/rotation and line endpoint editing, duplication, deletion, front/back
stacking, lock/unlock, object/connection/canvas style inspection and editing,
captions with box growth (measured with bundled Neo-Acid and Amatic SC faces
plus CoreText system cascade fallback), read-only attachment preview/copy,
canvas zoom/fit (`+`/`-`, `⇧1`, `⇧0`/`⌘0`), transparent Keynote PNG export
(`File → Export PNG…`, `⇧⌘E`) and Undo/Redo; native v2 code-snippet authoring
and syntax highlighting are deferred to the next phase of development (existing
v2 `code` nodes are preserved, rendered as plain text in `Monaspace Neon`,
transformed/styled/connected/duplicated with 1 MiB quota enforcement, and
exported to PNG).
[TASKS.md](TASKS.md) owns milestones, scope, acceptance proof, and unresolved
native decisions. The web app supports v1 and v2; new web documents use v2 with
an explicit code-node type.

## Repository organization

Keep the working Phoenix app and its Mix commands at the repository root.
[`macos/`](macos/) owns the independent native app;
[`shared/fixtures/`](shared/fixtures/) owns runtime-independent v1/v2 JSON
contract fixtures. Web tests consume the shared fixtures today; native checks
must use the same corpus rather than fork it. Copy fixtures to temporary files
before editing/saving. [`examples/`](examples/) remains editable user content.
Do not introduce a shared runtime or root build orchestrator for the native app.
The approved native foundation is Swift/AppKit for the canvas, inspectors and
document lifecycle, with Core Graphics/native text rendering in a Swift Package
with command-line `.app` bundling, targeting macOS 27. The app validates v1/v2
JSON via `CanvasDocument`, uses `CanvasSession` for in-memory transactions with
monotonically increasing revision tracking, and coordinates file persistence,
coalesced autosave, external-conflict pause, and draft/crash recovery through
`CanvasNativeDocument` (`NSDocument`) and `CanvasRecoveryStore`.
New is blank v2; saving existing v1 in-place leaves its version unchanged, while
`Save Version 2 Copy…` writes a separate v2 file. The app refuses unsupported
semantics. Routes are approximate and code is currently rendered as plain text.
attachment import is not. TASKS.md owns remaining gates.
The local bundler must ad-hoc sign and verify the assembled `.app`; the standalone
linker signature is not a valid substitute for the final bundle's seal.
[`macos/SPEC.md`](macos/SPEC.md) distinguishes approved choices from proposals;
neither the design nor approval establishes native compatibility.
[`shared/CODE_SNIPPETS.md`](shared/CODE_SNIPPETS.md) owns the supported shared
snippet schema, literal-source policy and explicit version-copy migration.
Existing v1 sources remain v1; conversion downloads a separate v2 snapshot and
requires explicit Open. Do not implement the superseded shape-metadata encoding,
silently upgrade/downgrade, or infer native implementation from web support.

## Architecture map

- Native [CanvasDocument](macos/Sources/CanvasCore/CanvasDocument.swift) validates
  supported v1/v2 input, retains original bytes, and encodes validated JSON snapshots.
  [CanvasJSON](macos/Sources/CanvasCore/CanvasJSON.swift) preserves literal strings,
  64-bit integers, and IEEE 754 `Double` round-trips via `JSONDecoder`/`JSONEncoder`
  (avoiding `JSONSerialization`'s leading-BOM stripping and `NSDecimalNumber` trig drift).
  Keep raw numeric-token validation before string-preserving decoding, then
  validate restored content/quotas; parsing happens on open, not geometry edits.
  [CanvasSession](macos/Sources/CanvasCore/CanvasSession.swift) owns mutable in-memory
  graph state, validated `encodedData()` snapshots, retained object/connection
  insertion/deletion/duplication identity and stacking, 1 MiB attachment/code duplicate
  quota checks, and lock/unlock; connection transactions validate endpoints and self-loop sides.
  [CanvasPersistence](macos/Sources/CanvasCore/CanvasPersistence.swift) (`CanvasFileFingerprint`,
  `CanvasPersistenceState`, `CanvasRecoverableTextDraft`, `CanvasRecoveryEnvelope`, and
  `CanvasRecoveryStore`) and [CanvasNativeDocument](macos/Sources/CanvasUI/CanvasNativeDocument.swift)
  (`NSDocument`) own coordinated safe saving, pre- and post-staging SHA-256 byte-fingerprint
  verification, coalesced 5s/30s autosave, external-change conflict pause (`Save As…`,
  confirmed `Reload from Disk…`, `Keep Editing`), `NSDocument` draft autosaving
  (`autosavedContentsFileURL`) paired with private `0600` recovery envelopes (without
  duplicating committed JSON snapshots), launch restoration, and close/quit guards.
  [CanvasTheme](macos/Sources/CanvasUI/CanvasTheme.swift) defines the light-first
  Neo-Acid canvas palette (`#f7f7f5` Raw Gallery Plaster background, `#ecece6`
  surface, `#0a0b0d` Ebony Ink for strokes and light/highlighter fills, `#ffffff`
  text on `ink` fills, and `#1a3bf5` Cobalt selection).
  [PNGExport](macos/Sources/CanvasUI/PNGExport.swift) (`CanvasTypography`,
  `CanvasPNGExportSizing`, `CanvasPNGExportPlan`, and `PNGExportSheet`) registers
  the bundled Neo-Acid (`Mona Sans` 400/700, `Unbounded` 800, `Monaspace Neon`
  400/700) and `Amatic SC` 700 faces from `macos/Resources/Fonts/` with CoreText
  system glyph fallback, and renders offscreen transparent sRGB PNG snapshots
  (2,048px default longest side or exact letterboxed dimensions, 32-unit padding,
  8,192px/side and 16,777,216px total caps, zoom/DPR invariant, no paper/grid/UI
  chrome) after flushing valid pending editors/previews.
  [CanvasView](macos/Sources/CanvasUI/CanvasView.swift)
  owns AppKit object/connection hit-testing, Tab traversal, Space tap/hold-pan,
  marquee and multi-selection, viewport-centered and adjacent-thought (`N`)
  insertion, inline on-canvas shape/text caption editing with live/committed box
  growth, zoom/fit (`+`/`-`, `⇧1`, `⇧0`/`⌘0`), duplication, deletion, front/back
  stacking, lock/unlock, rendering, PNG export snapshot capture, and explicit
  per-canvas history groups, not AppKit event-based grouping. Geometry/edges
  [CanvasGeometry](macos/Sources/CanvasCore/CanvasGeometry.swift) owns validated
  authored boxes, rotated-anchor math, adjacent-thought ray placement/blocker
  skipping, and standalone line endpoint geometry;
  [GeometryGesture](macos/Sources/CanvasUI/GeometryGesture.swift) keeps
  resize/rotation and line-endpoint previews outside session JSON until commit.
  Preserve omitted rotation and non-padded boxes on cancel/Undo/no-op; lines use
  endpoint semantics, not box scaling.
  [ShapeTextEditor](macos/Sources/CanvasUI/ShapeTextEditor.swift) (`AttachmentPreviewSheet`),
  [ConnectionEditor](macos/Sources/CanvasUI/ConnectionEditor.swift) (connection
  creation, label editing, and endpoint/side reconnection), and
  [StyleInspectorView](macos/Sources/CanvasUI/StyleInspector.swift) (object,
  connection, and empty-selection canvas `paper`/`appearance.font` controls) keep
  native sheets and the floating upper-right AppKit Style inspector synchronized
  with `CanvasSession` without materializing omitted defaults on observation;
  cancellation and no-ops leave history untouched.
  Pointer drags, geometry gestures, and inline text drafts stay outside committed
  `CanvasSession` JSON until commit so background autosave never serializes unconfirmed previews.
- [Document](lib/elixir_canvas/document.ex) owns v1/v2 JSON validation,
  metadata retention, source identity, version-copy preparation and server-file persistence.
- [Attachment](lib/elixir_canvas/attachment.ex) validates embedded UTF-8 snapshots
  in shape metadata and duplicate-inclusive byte limits. Ordinary Hakushi graph
  history owns import, removal and duplication; content stays outside captions.
- [CodeSnippet](lib/elixir_canvas/code_snippet.ex) validates literal UTF-8 source
  and duplicate-inclusive code quotas, independently of attachment budgets.
  [DrawingCode](lib/elixir_canvas_web/drawing_code.ex) owns the v2 code kit.
  [code_snippets.js](assets/js/code_snippets.js) owns generation-scoped source
  drafts, literal clipboard, fit and clipped-export checks; [literal_source.js](assets/js/literal_source.js)
  preserves line endings through textarea edits. [code_highlighter_worker.js](assets/js/code_highlighter_worker.js)
  runs local Shiki tokenization and conservative Highlight.js detection.
  Cache by stable DOM/source stamps, not native node-object identity: DOM
  rereads replace node objects and renderer mutations must not feed themselves.
  Image export must await current-source highlight readiness after fonts, including
  offviewport code. Stale replies cannot release the wait; worker failure must
  settle through explicit literal-text fallback, and generation changes refuse
  export rather than capturing an obsolete document.
  Code tool activation must visibly explain v1 restrictions before arming; expose
  the existing document conversion/New workflow, never auto-upgrade. Native click
  placement emits zero-sized geometry: give the local draft usable dimensions,
  while preserving dragged geometry and adding no node/history until Finish.
  Treat focus moves to editor actions/options as internal via `relatedTarget`;
  focus pointer-activated controls and checkbox labels before textarea blur.
  A transient body-focus interval must not commit before Cancel/Copy/options.
  Preserve checkbox-label focus on pointerdown without cancelling click/Space:
  the label's default focus reset to body must not prematurely commit the draft.
  Fit is an ephemeral unchecked checkbox, not a second finish action or metadata.
  Its pending choice must participate in preliminary file guards and commit
  source/geometry atomically only when the draft is finished.
  The displayed source body uses native node dragging; never blanket it with
  `data-hakushi-nodrag`. Keep controls/editor excluded, protect actual scrollbar
  tracks, and route overflow wheel scrolling without consuming native zoom or
  Space-pan gestures. Movement remains Hakushi history, not a parallel drag stack.
  Code Enter/F2 capture must defer to active direct-keyboard modes and gestures;
  use the existing hook's activeCanvas/directKeyboard bridge so C/G own Enter
  through completion instead of opening a second editor mid-mode.
- [FlightRecorder](lib/elixir_canvas/flight_recorder.ex) writes rotating development
  logs (`tmp/logs/dev.log`), a crash index (`tmp/logs/crashes.jsonl`), and
  self-contained server/client crash reproduction bundles (`tmp/crashes/crash-*.json`)
  containing git SHA, event parameters, stacktraces, and the in-memory versioned graph.
  [`mix canvas.doctor`](lib/mix/tasks/canvas.doctor.ex) (`--json`, `--strict`,
  `--clear-crashes`) inspects build/asset freshness, example corpus integrity,
  recent log errors, and crash bundles.
- [CanvasLive](lib/elixir_canvas_web/live/canvas_live.ex) coordinates the editor,
  document lifecycle, unsaved state, and save/reload flows.
- [DrawingShapes](lib/elixir_canvas_web/drawing_shapes.ex) and
  [DrawingTypography](lib/elixir_canvas_web/drawing_typography.ex) adapt Hakushi's
  Shapes kit for unfilled Neo-Acid defaults, standalone lines, and portable font roles.
- Hakushi owns ordinary graph operations and undo/redo.
  [DrawingCanvas](lib/elixir_canvas_web/drawing_canvas.ex) delegates its lifecycle
  and events, adding node stacking entries and validated connector-style commands
  to the same history. Optional `edge.data.connector_style` is projected through a
  root data attribute; unknown metadata remains server-owned. Document bridges
  the graph to the portable file contract.
- [app.js](assets/js/app.js) integrates LiveView and Hakushi in the browser,
  including drawing-font readiness and editor behavior, alongside
  [rotation_guides.js](assets/js/rotation_guides.js) and
  [self_loops.js](assets/js/self_loops.js).
  The self-loop integration also registers triangle connection handles from the
  kit's actual SVG polygon before native measurement; transformed routing sides
  are client-only, while persisted top/right/bottom/left names stay unchanged.
  [text_editor_geometry.js](assets/js/text_editor_geometry.js) previews multiline
  text growth through the guide/handle measurement path, retaining client-only
  height across native node rereads. Restore the baseline before native text
  finish so commit still persists growth and Escape leaves no preview/history.
- [style_inspector.js](assets/js/style_inspector.js) owns the upper-right floating
  Style inspector for objects and connections. Read effective native styles and
  typography without materializing defaults; expose only properties shared by
  the selected object types and label mixed values explicitly. Preserve native
  control identity/focus on same-selection patches. Mixed node/edge selections
  edit nodes only; commands retain native undo/history and metadata semantics.
- [connector_styles.js](assets/js/connector_styles.js) renders persisted named
  connector styles. Preserve native highlight/hit-target semantics and bounded,
  state-specific marker variants; inspector controls live only in style_inspector.
- [direct_keyboard.js](assets/js/direct_keyboard.js) adds selection-preserving
  object/edge traversal, Space tap selection (Space hold still pans), G geometry
  previews, staged C connections, inline edge labels and N adjacent thoughts.
  Root Tab entry anchors the first live selected drawing in canvas order; N falls
  back to one selected drawing only without selected edges or virtual edge focus.
  Thought drafts stay client-only; commit final text/box through one public
  `hakushi:draw`/`Change.add`, never create-then-edit/delete. Preserve native
  `lastFocus` bookkeeping when focusing without changing selection. Save flushes
  drafts/geometry and awaits success; invalid drafts block persistence. Open
  retains its unsaved guard. Escape cancels a mode/editor before closing Style.
  The compact ? map lives in the document menu.
- [zen_mode.js](assets/js/zen_mode.js) owns session-local workspace visibility,
  never document metadata or fullscreen state. Keep existing save/draft/error
  feedback visible while hiding non-drawing chrome. Mode transitions preserve
  native selection, view, tools, pending editors and history; focus recovery
  suppresses native focus-in selection/reveal side effects and updates lastFocus.
  Retain direct-mode drafts when focus visits `[data-zen-toggle]`. Escape defers
  to active editors/modes/tools/overlays before exiting; explicit Style/help/Open
  requests reveal normal UI instead of focusing hidden controls.
- [native_file.js](assets/js/native_file.js) handles browser file selection,
  native-handle persistence, and copy-download fallbacks.
- [text_attachments.js](assets/js/text_attachments.js) imports text snapshots via
  the native draw/history path and fetches full content only for a read-only
  native-dialog preview/download. `app.js` exposes the generation-scoped
  `fileCanvas` instance on its hook element. Preview hit-tests double-clicks
  because native pointer capture may retarget them to the canvas root; Enter/F2
  defer to active editing modes. Keep source text literal and downloads inert.
- [canvas_messages.js](assets/js/canvas_messages.js) owns notification popover
  enhancement/fallback, informational expiry, and notification focus handling.
  CanvasLive retains errors/conflicts when details are dismissed; the save status
  reopens them. Notice dismissal is acknowledgement-token/generation scoped.
  Routine save success belongs only in save status; copy feedback never replaces
  unresolved source errors or changes persistence/dirty state.
- [tokens.css](assets/css/tokens.css) holds shared design primitives;
  [app.css](assets/css/app.css) applies workspace and drawing styles.
- [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
  [LICENSE](LICENSE) define open-source contributor checks, local-server security
  boundaries, and MIT/font licensing.

## Document and data safety

Preserve compatibility with existing version-1 canvas files and source versions
on ordinary saves/copies. Discuss further format changes before implementation.
Canonical rules are in [README: v1](README.md#document-format-version-1),
[README: v2](README.md#document-format-version-2) and the shared snippet contract.
Code source preserves BOM, tabs, Unicode, CR/LF/mixed line endings and unknown
metadata. No execution, formatting-on-save, tokens/themes in JSON, or attachment
on code nodes. Enforce byte limits on source/type/add boundaries, not geometry.
Source and optional language/box edits use native history atomically; locked
source edits refuse server-side. Pending invalid/composing code drafts veto file
and image operations, remain editable and never silently save the previous graph.

Text attachments are embedded copies, never filesystem links or browser handles.
Preserve UTF-8 content, BOM, line endings and unknown attachment metadata; enforce
per-file/aggregate limits on decode, save and node additions/data/type updates,
including paste/duplicate/undo. Avoid rescanning content on ordinary geometry
changes. Pending imports participate in file flushes and unload warnings; stale
generations cannot add or preview content. Development crash bundles can contain
the complete attachments and code source as document data.

Preserve metadata on retained objects, authored geometry and corner choices,
portable named colors, and generic typography roles. Resolve theme colors and
font families in the renderer; changing a view's theme must not dirty documents
or rewrite their geometry or style names. Wait for the resolved drawing font
before measuring canvas text or enabling editing.

Adjacent thoughts use fresh default rectangles/document typography, not source
metadata clones or proximity links. Keep full measured geometry independent
from the bounded scrolling draft editor; preview placement/reveal policy is in
[README: Keyboard editing](README.md#keyboard-editing). Pending draft status
derives from the preview DOM, not server dirty/history.

A browser-selected filename is not a server path. Never infer a server location
from it or redirect its Save to the initial document. Keep server-path files,
browser handles, and downloaded copies distinct, including truthful save/dirty
state and external-change handling. See [README: Run](README.md#run) and
[README: Edit](README.md#edit) for the persistence contract and its limits.

Explicit **Save a copy** downloads a validated snapshot from every source mode
after flushing pending editors/previews. Unlike ordinary fallback Save copy or
first native Save, it never promotes/reassigns a source, advances the baseline,
clears dirty/conflict state, or resets history. Preserve unresolved original-file
errors when acknowledging a copy; generation/token checks and busy guards still
apply. Report download initiation only, not confirmed disk persistence; browser
download-manager cancellation/failure is not observable.

`Document.new/0` returns a blank v2 `:untitled` document without a path or revision.
New canvas flushes drafts/text/code, then refuses unsaved work or a busy file operation;
it remounts a generation-scoped board and returns keyboard focus after readiness.
Graph notifications, selected-file callbacks and save acknowledgements are
generation-scoped. The first successful native Save promotes only the saved
snapshot to `:browser_file`, preserving newer graph edits and history. Unsupported
native saving becomes `:save_copy` only after download acknowledgement, retaining
the pre-download baseline and nil revision (no connected source), with honest
unsaved state. Neither untitled state nor downloads may reuse a previous path or
handle. Preserve native browser New shortcuts; no discard flow is implied.

`Document.normalize_filename/1` validates authored names, and `Document.rename/2`
changes only `filename` for pathless, revisionless `:untitled` / `:save_copy`
documents. Names are ephemeral session identity, never document JSON metadata
or a filesystem rename; dirty/history/generation remain unchanged. Rename submits
a generation string and refuses pending saves so acknowledgements cannot restore
an older name. First Save snapshots the current suggested name, but a chosen
browser handle's actual name is authoritative and must not pass through authored
name normalization. Opened copies with a revision are not renameable.

## Decision policies

Implement requested changes directly by default. Restate the plan and wait only
when explicitly requested. Commit only when requested.

For the existing web app, reuse the Elixir/Phoenix/LiveView/Hakushi stack and
vanilla CSS. Ask before adding any dependency or build step; this does not
prohibit using existing ones.

Web desktop behavior should work in Chrome, Edge, Safari, and Firefox. Use
progressive enhancement: feature-detect optional browser APIs and provide honest
fallbacks rather than implying unsupported capabilities succeeded.

## Design guidance

For web interface changes, read [DESIGN.md](DESIGN.md), prioritizing its opening
Elixir Canvas adaptation over the source kit's generic defaults. Keep the canvas
dominant, with floating controls, square corners, and flat surfaces. Acid marks
the active tool; hover stays neutral. Cobalt marks object selection and focus.

Single-character drawing shortcuts belong only to focused canvas/objects, never
form controls or composing text. Browser zoom must remain reachable outside canvas
focus. File/style Escape returns focus to the trigger; native popovers own their
dismissal. Keep the in-app **?** map and README keyboard section aligned with
actual behavior; do not invent shortcuts for unsupported file workflows.

The approved Mona Sans/Monaspace Neon project pairing overrides the vendored
design skill's font list, not its other guardrails. See
[DESIGN: Typography](DESIGN.md#3-typography) for font inventory, weights, role
mapping, and inspector behavior rather than duplicating those rules here.

The native Mac interface pairs Apple Human Interface Guidelines for window
chrome, menus, and modal sheets (pinned to Light Aqua appearance to match the
light-first canvas) with the Neo-Acid canvas palette (`CanvasTheme`), Cobalt
selection, and the branded Welcome window. It shares the JSON contract's
geometry, named colors, and semantic font roles, not the web runtime.

## Setup and verification

[README: Run](README.md#run) is canonical for web prerequisites, including Node.js
22+ and npm. `mix setup` installs locked npm dependencies; `mix assets.deps`
refreshes them after lockfile changes. [README: Checks](README.md#checks) lists
CLI verification and browser limits. [mix.exs](mix.exs) defines aliases:
`mix check` is read-only verification; `mix precommit` formats and can change locks.

The native milestone's setup and verification instructions must be supplied with
implementation; current Mix/browser checks are not native application proof.

Minimize token usage during verification by using the lightest sufficient proof:
1. **Server, document, and LiveView behavior:** Verify with `mix test` (`Phoenix.LiveViewTest`)
   and temporary files. Do not launch a browser for behavior covered by Elixir tests.
2. **Client-side JS logic:** Verify with `node --check` and targeted Node scripts/tests
   before considering a browser.
3. **Visual/CSS or browser-only DOM behavior:** Only launch a browser when changes
   cannot be verified via `mix test` or Node (or when explicitly requested). When
   using a browser:
   - Delegate browser verification to a subagent so DOM snapshots and screenshots
     do not bloat the main conversation context.
   - Prefer a single batched `evaluate_script` state assertion over multi-turn
     interactive clicking and repeated full-page snapshots/screenshots.
   - Check only the specific changed control, never the full [README manual QA checklist](README.md#manual-browser-verification).

When exercising saves in tests or the editor, always use temporary canvases:
[examples/welcome.json](examples/welcome.json) is a real editable source document,
not a disposable fixture. Narrow-layout checks are not mobile interaction testing.

## Completion evidence

Before behavior changes, identify the user scenario, observable expected outcomes,
and relevant failure cases. Derive expectations from requirements, not implementation.
Run relevant existing checks and inspect actual state and side effects (such as
rendered DOM via `LiveViewTest`, saved JSON bytes, or targeted JS assertions),
not logs, screenshots, or self-reports alone.

For bugs, establish failing evidence and root cause, then repeat the same scenario
after the fix. Add a useful deterministic regression when practical. Permanent tests
should protect behavior contracts through refactors, not private helpers, copied
constants, source structure, or incidental wording.

For persistence, use the temporary canvases described above: verify real saved bytes
and dirty state, plus relevant cancellation, failure, conflict, and fallback paths.
Report executed checks, observed outcomes, and material limits honestly. Masking an
API does not establish Safari/Firefox compatibility; OPFS does not exercise an OS
file dialog.

For docs-only changes, review content, paths, and links; no app run is needed unless
behavior also changes.

## Artifact maintenance

Before declaring significant behavior, architecture, setup, verification, file-format,
or workflow changes complete, review AGENTS.md and README.md plus affected docs,
examples, and verification instructions as relevant. Update stale guidance,
paths, and contracts; remove obsolete claims in the same change, aligned with
verified behavior. Keep durable agent context and policies in AGENTS.md; setup,
user behavior, schemas, and check recipes in README.md; visual rules in DESIGN.md.
Avoid duplication. Accurate files may remain unchanged; whitespace-only changes
need no review. Briefly report artifacts updated or reviewed unchanged, without
a ceremonial checklist.
