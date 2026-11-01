# Backlog

Plan only: the scope below is not a claim of implemented behavior.
Priority: current web milestone (front/back → connected-arrow styling), then native macOS.
Use the existing [document contract](README.md#document-format-version-1),
[checks](README.md#checks), and [agent policy](AGENTS.md); do not duplicate them here.
This promotion is planning only: no app scaffolding, toolchain installation,
dependencies, build steps, or CI changes until implementation is requested.

## Current milestone: web editing

### 1. Bring selected drawing objects to front / send to back

- [ ] **Outcome:** control which overlapping drawing objects appear above others.
- **Scope:** Bring to front and Send to back for selected drawing nodes, using
  existing version-1 `nodes` array order (back to front).
  No full layer panel, auto-layout, or new lock semantics.
- **Acceptance:** only stacking changes; preserve all objects' positions, styles,
  metadata, and connections. Follow existing selection behavior; retain selected
  objects' relative order and unselected objects' relative order. No selection
  or an already-front/back selection must not cause
  spurious document changes, dirty state, or history entries.
- **Proof:** overlap several objects, select and reorder in both directions;
  each effective command is one undoable action, with redo restoring the order.
  Check no-selection, already-front/back, and multi-selection cases.
  Save a temporary document, inspect `nodes` order, and reopen to confirm overlap
  survives without geometry, style, or connection changes.

### 2. Style connected arrows

- [ ] **Outcome:** select a connected arrow and edit its agreed appearance.
- **Before implementation:** agree minimum properties and storage (decision below);
  discuss any required format change first.
- **Scope:** connected arrows, not a duplicate standalone-line inspector:
  standalone Line/Arrow already expose Style color, width, dash, and heads.
  Reuse the existing style vocabulary for supported properties; preserve bindings,
  self-loops, and the free-standing Line tool. No new attachment behavior.
- **Acceptance/proof:** select a connected arrow → apply each agreed style →
  move its endpoint shapes → undo/redo → save and reopen a temporary document.
  Check ordinary connections and self-loops retain their bindings and appearance;
  style edits undo/redo correctly, unrelated objects remain unchanged, and plain
  Lines remain free-standing. Inspect saved bytes against the agreed file contract.

## Next milestone: independent native macOS editor

- [ ] **Outcome:** open an existing version-1 JSON canvas in an independent native
  Mac editor, select/move objects, edit text, undo/redo, save, and reopen in both
  editors; export a transparent high-resolution PNG suitable for Keynote.
- **Purpose:** personal structured brainstorming, developer systems diagrams,
  facilitated sessions, and illustrations for presentations.
- **Committed direction:** native UI follows Apple Human Interface Guidelines,
  not Neo-Acid. No wrapper, webview, Phoenix server, or BEAM runtime in the Mac app.
  Share the [version-1 file contract](README.md#document-format-version-1),
  not a runtime; preserve authored geometry, semantic font roles, and named colors.
  Native font/palette resolution may differ; pixel-identical rendering is not required.
- **Before project creation:** confirm repository organization. Recommended, not
  approved: monorepo with the web app left at the root, a separate `macos/` project,
  and shared contract fixtures; independent builds and runtimes. Swift with AppKit,
  SwiftUI, and Core Graphics is a candidate, not an approved architecture.
- **Before implementation:** decide minimum macOS, SwiftUI/AppKit responsibilities,
  the initial supported document-content/editing scope, and PNG default dimensions
  and maximum output size. Do not imply full web feature parity.
- **Compatibility gate:** agree fixtures covering supported shapes/text, standalone
  lines, connections/self-loops, rotations, locks, and metadata. Unsupported content
  must be identified before editing: reject it clearly or open read-only without
  loss; never silently omit it or permit a lossy save.
- **Round-trip proof:** on temporary fixture copies, open → render → select/move →
  edit text → undo/redo → save → reopen in web and native. Compare actual JSON:
  stable IDs, node stacking order, bindings and handles, styles, unknown metadata,
  named colors/font roles, and unedited authored geometry survive; only intended edits differ.
  Plain Line remains free-standing. Renderer font/theme choices must not dirty files.
- **Mac workflow proof:** native menus, keyboard commands, file dialogs, and window
  lifecycle work together. Exercise dirty close/quit/open prompts, cancel, invalid
  files, failed writes, and external-change conflicts; keep edits and source intact.
  Use atomic replacement with conflict checks; document remaining race/durability
  limits rather than claiming filesystem locking.
- **PNG proof:** choose explicit output pixel width/height or scale, independent
  of viewport zoom and screen DPR. Wait for resolved fonts; include padding and
  full labels/strokes/arrowheads, with true alpha and no paper/grid/UI background.
  Inspect actual PNG dimensions/alpha, compare exports at different zoom/DPR, and
  place the export on actual light and dark Keynote slides to check transparency,
  legibility, and unclipped content. No SVG/PDF requirement in this milestone.
- **Boundary:** a small complete native workflow, not web parity, cloud, accounts,
  multiplayer, or additional platforms. Implementation must supply native setup and
  proof instructions; current Mix/browser instructions remain web-only.

## Later

- [ ] **File-menu scrolling:** make the menu compact and usable without clipping,
  including keyboard access and short windows; do not merely hide the scrollbar.

## Needs decision

- [ ] **Connected-arrow appearance (blocks current milestone 2):** agree minimum properties
  first. Check [node style vocabulary](README.md#nodes) against the existing
  [edge contract](README.md#edges), including marker semantics and storage.
  Do not assume standalone node style fields are already an edge-style contract.
  Discuss any file-format change before code, preserving version-1 compatibility.
- [ ] **Favicon:** the root layout already references `/images/logo.svg` and
  `/favicon.ico`; confirm desired branding and the remaining gap before changing
  assets or marking this complete.

## Resolved design note

- **“Do we need nodes to connect an arrow/line so it follows when moved?”**
  Existing bound arrows already follow their endpoint shapes
  ([current behavior](README.md#edit)). Keep plain Line free-standing, including
  when drawn between shapes; do not turn the old question into attached-Line work.

## Done

- [x] redesign with acid theme
- [x] canvas styling using acid theme
- [x] add zoom in and zoom out shortcut to override default browser zoom in and
      zoom out
- [x] add a line
- [x] ability to do a loop with arrow/line
- [x] Do rotation, the drawing item is rotating, but the guide nodes stay still.
      I think it's a bug
- [x] Load file using os's native load file
