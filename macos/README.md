# Native macOS editor

This directory contains an independent native canvas app with session-only
New, shape/text insertion, connections, selection, movement, resize/rotation,
caption editing and Undo/Redo. The planned editor is not complete: there is no
saving, style editing, line/code creation, recovery, attachment preview, syntax
highlighting or PNG export.

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

Use **Insert → Rectangle / Ellipse / Diamond / Triangle / Text…** to add content
at the current viewport center, including after scrolling. With
canvas focus, **R / O / D / I / T** perform the same commands; these keys stay
ordinary text inside the editor. Shapes start unfilled with an ink outline and
inherit document typography. New text stays in its sheet until committed; Cancel
or empty Done creates nothing. Each insertion is one undoable action; Redo retains its ID.
Inserting repeatedly uses the same center; drag each object to arrange it.

Click an object to select it; drag it, or use Arrow keys (Shift-Arrow moves 10
world units). Locked objects can be selected but not moved or edited.
Command-Z and Shift-Command-Z undo/redo insertions, connections, completed moves,
resize/rotation and caption changes. Each command is a separate transaction, even
when several commands arrive in one event. Native text editors retain their own
text history.

Selected unlocked shapes and code blocks show eight resize handles and a round
rotation handle. Drag a handle and release to commit; **Escape** cancels.
Resize follows the object's rotated local axes with the opposite corner/side
fixed. Crossing the fixed anchor clamps instead of flipping the object. Ordinary
interactive sizes stop at one world unit; existing smaller authored sides remain
unchanged unless deliberately resized.

For keyboard geometry, select an object and press **G**, or use
**Edit → Edit Geometry**:

- Start on the bottom-right handle; **Tab / Shift-Tab** cycles resize/rotation handles.
- **Arrows** move the resize handle along local axes by 1 unit; **Shift-Arrows** by 10.
- On the rotation handle, Left/Up subtract 1 degree and Right/Down add 1;
  Shift changes the step to 15 degrees.
- **Return** commits the whole preview once; **Escape** cancels. Undo/Redo first
  cancels a pending preview before touching committed history.
- Clicking away from handles cancels the preview before normal selection/movement.
  Insert commands are disabled while geometry is pending.

Geometry previews and rerouted connections stay outside committed JSON until
commit. Cancellation/no-op preserves Redo, metadata and omitted rotation fields.
Standalone lines do not use box resize/rotation yet; their endpoint editing is pending.

Select a source object and press **C**, or choose **Insert → Connection…**.
Choose source/target objects and Automatic or named attachment sides, then
**Create Connection** (Return). **Cancel** (Escape) makes no change and preserves
Redo. With no selection the source defaults to the first object; an empty canvas
disables the menu command. A single-object canvas defaults to a right-to-top
self-loop. Self-loops require two different named sides; invalid choices stay in
the sheet with an error. Connecting to a locked object does not modify that object.
Connections are curved arrows; moving, resizing or rotating either endpoint remeasures
the route without rewriting its stored sides. Exterior routes expand the scrollable canvas
without shifting the current view. Undo removes the new connection; Redo restores
its ID, bindings and order. Connection selection, labels, reconnection, style
editing and deletion are not implemented yet.

Double-click an unlocked shape, or select it and press Return, to edit its caption
in a native sheet. Return inserts a newline; **⌘Return** or **Done** commits;
**Escape** or **Cancel** discards the draft. Text is limited to 2,000 graphemes;
an invalid draft stays open without truncation. Code, line and connection text
editing are not implemented. Attachment cards edit only their caption, not content.
Text edits retain authored geometry; automatic box growth is not implemented.

The app never saves or changes source files. Closing the window discards session
changes without a confirmation prompt. It validates versions, graph references,
content limits and supported rendering semantics before opening; unsupported
documents are refused with a message. Some valid web canvases may be refused,
including self-loops without two distinct named side handles and geometry outside
the native app's bounds. The canvas uses the light-first Neo-Acid color palette while
fonts and connector routes remain native approximations;
code is plain text and attachments are cards, not previews. No zoom or export.

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
padding and caps of 8,192 pixels per side / 16,777,216 pixels total. HighlighterSwift
is the approved highlighting candidate; it is not yet added or proven in the app.
Recovery details, native file UX, font mappings and shortcuts remain decisions.
The current app does not establish editable web/native compatibility. Web verification
still runs with `mix check` from the repository root; it does not build or verify
the native app.
