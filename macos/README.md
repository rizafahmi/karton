# Native macOS editor

This directory contains an independent native canvas app with session-only
New, shape/text and standalone line/arrow insertion, adjacent thoughts (`N`),
connections (including labels and endpoint/side reconnection), object/connection
selection, selection-preserving Tab traversal, Space tap selection toggle and
Space-drag panning, marquee and Shift-click/⌘A multi-selection, movement,
resize/rotation and line endpoint editing, duplication, deletion, front/back
stacking, lock/unlock, object/connection/canvas style editing, caption editing
with automatic box growth (using bundled Neo-Acid and Amatic SC typography with
CoreText system glyph fallback), read-only attachment source preview/copy, canvas
zoom/fit (`+`/`-`, `⇧1`, `⇧0`/`⌘0`), transparent PNG export (**File → Export PNG…**,
**⇧⌘E**) and Undo/Redo. The planned editor is not complete: there is no JSON
saving, code creation, recovery or syntax highlighting.

## Build and run

Requires macOS 27 and Apple's Command Line Tools with Swift and the macOS SDK.
Full Xcode is not required. From the repository root:

```sh
sh macos/build.sh
open "macos/.build/Elixir Canvas.app"
```

The build assembles the `.app`, ad-hoc signs the complete bundle with the system
`codesign` command, then strictly verifies its seal. No signing certificate or
Apple developer account is needed for this local build. Ad-hoc signing is not
Developer ID signing, notarization, or a distribution guarantee.

Use **File → New** (**⌘N**) or **New Canvas** in the welcome window to start a
blank version-2 canvas. **File → Open…** opens supported v1/v2 JSON files.
Each New/Open creates a separate session window without replacing existing work.

Use **Insert → Rectangle / Ellipse / Diamond / Triangle / Text…** or
**Insert → Line / Arrow** to add content at the current viewport center, including
after scrolling. With canvas focus, **R / O / D / I / T** and **L / A** perform the
same commands; these keys stay ordinary text inside the editor. Shapes start
unfilled with an ink outline and inherit document typography; standalone lines and
arrows remain free-standing (`type: "shape-line"`, never bound to objects). New
**T** text opens an inline on-canvas draft editor at the viewport center until
committed; Escape or an empty Return creates nothing. Each
insertion is one undoable action; Redo retains its ID. Inserting repeatedly uses the
same center; drag each object to arrange it.

Click an object or connection (curve or label pill) to select it, Shift-click or
drag a marquee box on empty canvas space (or press **⌘A**) to select multiple
objects, or press **Tab / Shift-Tab** to cycle through objects and connections in
canvas order. Tap **Space** to toggle selection of the focused item while keeping
traversal selection-preserving; hold **Space** and drag to pan the viewport
without changing selection or history. **Escape** cancels an active draft/gesture
or closes Style before clearing the selection. Drag selected unlocked objects, or
use Arrow keys (Shift-Arrow moves 10 world units). Use **View → Zoom In / Zoom Out /
Actual Size / Zoom to Fit** (or canvas **+ / -**, **⇧0** / **⌘0**, **⇧1**, and
trackpad pinch magnification) to scale and fit the viewport without mutating
document coordinates.

With a single unlocked shape selected or focused, press **N** (or choose
**Insert → Adjacent Thought**), then press a cardinal arrow (**↑ / → / ↓ / ←**) to
place an inline thought draft 48 world units beyond the source's rotated bounds
(automatically skipping any rotated blockers along that ray). Type inline
(**Shift-Return** inserts a newline; **Return** commits in one undoable step and
focuses the new rectangle for an immediate chained **N**; **Escape** cancels
either stage without touching history). As multiline text grows, the preview box
grows and rechecks ray blockers.
For the selected unlocked object:

- **Edit → Duplicate** (**⌘D**) adds an unlocked copy offset by `(+24, +24)` with a
  fresh ID while enforcing the 1 MiB attachment and code source quotas.
- **Edit → Bring to Front** (**⇧⌘]**) and **Edit → Send to Back** (**⇧⌘[**) reorder
  overlapping objects without changing positions, styles, metadata or connections.
- **Edit → Delete** (**Delete** / **Forward Delete**) removes the selected unlocked
  object (together with any incident connections) or the selected connection in one
  undoable step.
- **Edit → Lock / Unlock** (**⌘L**) toggles `locked` on the selected object. Locked
  objects can be selected and unlocked, and connections attached to them can be
  deleted, but locked objects cannot be moved, resized, rotated, edited, styled,
  duplicated, reordered or deleted.
- **Edit → Style…** (**S**) opens the upper-right floating AppKit Style inspector
  for the selected object or connection, or for the canvas (**Paper**, **Grid size**
  and **Default text**) when nothing is selected. It exposes only properties supported
  by the active target (fill, stroke, stroke width, solid/dashed, corners,
  arrowheads, text style/size/alignment, connection `connector_style`
  stroke/width/dash plus path and target marker, or canvas `paper.background`,
  `paper.grid` and `appearance.font`), reads inherited typography and
  defaults without materializing them, retains `animated` when changing connection
  dash, and visibly refuses non-object `connector_style` metadata collisions.
  **Escape** cancels active geometry previews before closing Style, and closes
  Style before clearing selection.
Command-Z and Shift-Command-Z undo/redo insertions, connections, connection
reconnections/label edits, completed moves, resize/rotation, duplication, deletion,
front/back stacking, lock/unlock, object/connection/canvas style edits and caption
changes. Each command is a separate transaction, even when several commands arrive
in one event. Native text editors retain their own text history.

Selected unlocked shapes and code blocks show eight resize handles and a round
rotation handle; selected unlocked standalone lines and arrows show two round
endpoint handles (`start` and `end`). Drag a handle and release to commit;
**Escape** cancels.
Shape resize follows the object's rotated local axes with the opposite corner/side
fixed. Crossing the fixed anchor clamps instead of flipping the object. Ordinary
interactive sizes stop at one world unit; existing smaller authored sides remain
unchanged unless deliberately resized. Line endpoint drags recompute the canonical
12-unit padded bounding box and relative `from` / `to` coordinates while preserving
positive dimensions for horizontal, vertical, and reversed segments.

For keyboard geometry, select an object and press **G**, or use
**Edit → Edit Geometry**:

- Shapes and code blocks start on the bottom-right handle; standalone lines and
  arrows start on the start endpoint. **Tab / Shift-Tab** cycles handles or endpoints.
- **Arrows** move the active resize handle along local axes (or the active line
  endpoint in world coordinates) by 1 unit; **Shift-Arrows** by 10.
- On the rotation handle, Left/Up subtract 1 degree and Right/Down add 1;
  Shift changes the step to 15 degrees.
- **Return** commits the whole preview once; **Escape** cancels. Undo/Redo first
  cancels a pending preview before touching committed history.
- Clicking away from handles cancels the preview before normal selection/movement.
  Insert commands are disabled while geometry is pending.

Geometry previews and rerouted connections stay outside committed JSON until
commit. Cancellation/no-op preserves Redo, metadata, non-padded line boxes and
omitted rotation fields.

Select a source object and press **C**, or choose **Insert → Connection…**.
Choose source/target objects, Automatic or named attachment sides and an optional
label, then **Create Connection** (Return). **Cancel** (Escape) makes no change and
preserves Redo. With no selection the source defaults to the first object; an empty
canvas disables the menu command. A single-object canvas defaults to a right-to-top
self-loop. Self-loops require two different named sides; invalid choices stay in
the sheet with an error. Connecting to a locked object does not modify that object.
Select an existing connection and press **Return** / double-click (focusing its
label field) or press **C** / choose **Edit → Edit Connection…** to edit its label
and reconnect its source/target objects or attachment sides in one undoable step.
Connections are bound arrows; moving, resizing or rotating either endpoint remeasures
the route without rewriting its stored sides. Exterior routes and labels expand the
scrollable canvas without shifting the current view. Undo removes or restores the
connection; Redo preserves its ID, bindings and order.

Double-click an unlocked shape (or choose **Edit → Edit Text…**, or select a shape
without an attachment and press **Return**) to edit its caption inline directly on
the canvas. **Shift-Return** inserts a newline; **Return** or **⌘Return** commits;
**Escape** discards the draft. Text is limited to 2,000 graphemes; an invalid draft stays open
without truncation. As multiline text exceeds the initial box height, the shape
previews and commits the grown height in a single undoable transaction (keeping the
top anchor fixed on rotated shapes, measured with the bundled Neo-Acid and Amatic SC
faces plus CoreText system cascade fallback); cancelling restores the original text and height.
Double-click or press **Return** on a shape with an embedded text attachment (or
choose **Edit → Preview Attachment…**), including locked cards, to open a read-only
literal UTF-8 source preview sheet with **Copy Source**; previewing and copying
never modify the document or undo history. Code and standalone-line text editing
are not implemented.

Use **File → Export PNG…** (**⇧⌘E**) to export the canvas as a transparent sRGB
PNG suitable for Keynote. Choose **Longest side (proportional)** (default `2048` px)
or **Exact dimensions (letterboxed)** (up to `8,192` px per side and `16,777,216` px
total) with `32` world units of padding around all rotated shapes, text, standalone
lines/arrows, self-loops, markers and connection labels. Exporting flushes valid
pending inline text drafts or geometry previews once (cancelling an unplaced `N`
direction chooser without history and refusing invalid drafts with text intact),
excludes paper background, grid, selection outlines, handles and inspector chrome,
and produces identical output regardless of viewport zoom, scroll position or display
scale.

The app never saves or changes JSON source files. Closing the window discards session
changes without a confirmation prompt. It validates versions, graph references,
content limits and supported rendering semantics before opening; unsupported
documents are refused with a message. Some valid web canvases may be refused,
including self-loops without two distinct named side handles and geometry outside
the native app's bounds. The canvas uses the light-first Neo-Acid color palette and
bundled Neo-Acid/Amatic SC fonts while connector routes remain native approximations;
code is plain text.
Run the standalone native contract and round-trip checks from the repository root:

```sh
swift run --package-path macos -Xswiftc -target -Xswiftc "$(uname -m)-apple-macosx27.0" CanvasChecks
```

The Command Line Tools on the development machine lack XCTest and Swift Testing;
the check executable does not require either. Build artifacts stay in
`macos/.build/`. The current linker reports missing Command Line Tools search-path
warnings on the development machine even when the build succeeds.

## Boundaries

- The Phoenix web app stays at the repository root with its existing Mix commands.
- The native app must run without Phoenix, BEAM, a webview, or the web asset bundle.
- The editors share JSON contracts and fixtures, not a runtime. Preserve the
  [version-1 contract](../README.md#document-format-version-1) and the
  [version-2 contract](../README.md#document-format-version-2), using both
  [`shared/fixtures/`](../shared/fixtures/) versions. The native app renders code
  as plain text; the full native [code contract](../shared/CODE_SNIPPETS.md)
  remains pending.
- Shared fixtures are checked-in compatibility inputs. Copy them to temporary
  locations before editing or saving; do not maintain native-only copies of the
  same contract fixtures.
- Native window chrome, menus, and sheets follow Apple Human Interface Guidelines
  under Light Aqua appearance, paired with the light-first Neo-Acid canvas
  palette (`CanvasTheme`), Cobalt selection, and branded Welcome window. Preserve
  authored geometry, named colors, semantic font roles, and unknown metadata
  across document round-trips.

## Planned editor direction

The intended native editor is for personal use. It will support creating and editing
canvases, not just opening boards authored in the web app: New → shapes/text →
connect/rearrange → autosave JSON → export for Keynote. It must be useful without
launching the web app. Initial content includes shapes/text, standalone lines/
arrows, connections and v2 code. Existing attachments can be preserved, previewed,
exported, duplicated and removed; importing new attachments is outside the initial
scope. This is not full web parity.

Local build/launch comes first. Public distribution, Developer ID signing,
notarization, updates, and an app store are not first-release requirements.

Editing is keyboard-first with full mouse/trackpad support. Prioritize rapid
thought entry, adjacent thoughts, and keyboard connections without replacing
native text editing or standard Mac commands.

In the planned editor, connected documents autosave to their JSON source; explicit
Save remains available. The current app implements neither. Recover committed work and
acknowledged active text drafts; request autosave and recovery writes after 5
seconds quiet or within 30 seconds of
continuous changes. These are request targets, not durability guarantees.
Retain recovery until saved elsewhere or explicitly discarded, without silent
expiry; incomplete IME composition and changes after the last recovery write may
be lost. Autosave retains undo history. On an external conflict it pauses while
the user chooses Save As, confirmed Reload or Keep Editing. Recovery is offered
on launch; changed-source work restores separately as untitled. Close/quit waits
for valid work and writes, or offers return, recovery retention or explicit
discard. Detailed storage/cleanup and other file-operation behavior remain open.
The web app's explicit-save behavior is unchanged.

## Remaining work

The [implementation specification](SPEC.md) describes proposed canvas interactions,
autosave/recovery, compatibility coverage, native components, export, and acceptance
scenarios. Its decision table distinguishes recommendations from approved direction.

[TASKS.md](../TASKS.md#final-milestone-independent-native-macos-editor) owns the
native scope, unresolved decisions, and acceptance requirements. Approved on
2026-11-05: macOS 27, Swift/AppKit canvas, inspectors and document lifecycle,
Core Graphics/native text rendering, Swift Package and command-line `.app` bundling.
PNG defaults to a 2,048-pixel longest side with configurable dimensions, 32-unit
padding and caps of 8,192 pixels per side / 16,777,216 pixels total (implemented
and verified with bundled Neo-Acid typography and Keynote slides). HighlighterSwift
is the approved highlighting candidate; it is not yet added or proven in the app.
Recovery details and native file persistence UX remain decisions.
The current app does not establish editable web/native compatibility. Web verification
still runs with `mix check` from the repository root; it does not build or verify
the native app.
