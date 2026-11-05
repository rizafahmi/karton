# Native macOS editor

This directory contains an independent native canvas viewer with session-only
selection, movement and shape-caption editing. The planned editor is not complete:
there is no saving, style editing, creation, recovery, attachment preview, syntax
highlighting or PNG export.

## Build and run

Requires macOS 27 and Apple's Command Line Tools with Swift and the macOS SDK.
Full Xcode is not required. From the repository root:

```sh
sh macos/build.sh
open "macos/.build/Elixir Canvas.app"
```

Use **File → Open…** or the welcome-window button to choose a canvas. Each file
opens in a session-only window. Click an object to select it; drag it, or use
Arrow keys (Shift-Arrow moves 10 world units). Locked objects can be selected but
not moved or edited. Command-Z and Shift-Command-Z undo/redo completed moves and
caption changes. Movement updates connected routes in memory.

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
the viewer's bounds. Fonts, colors and connector routes are native approximations;
code is plain text and attachments are cards, not previews. No zoom or export.

Run the standalone native contract checks from the repository root:

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
  [`shared/fixtures/`](../shared/fixtures/) versions. The viewer renders code
  as plain text; the full native [code contract](../shared/CODE_SNIPPETS.md)
  remains pending.
- Shared fixtures are checked-in compatibility inputs. Copy them to temporary
  locations before editing or saving; do not maintain native-only copies of the
  same contract fixtures.
- Native UI follows Apple Human Interface Guidelines rather than the web app's
  Neo-Acid styling. Preserve authored geometry, named colors, semantic font roles,
  and unknown metadata across document round-trips.

## Planned editor direction

The intended native editor is for personal use. It will support creating and editing
canvases, not just opening boards authored in the web app: New → shapes/text →
connect/rearrange → autosave JSON → export for Keynote. It must be useful without
launching the web app. Initial content includes shapes/text, standalone lines/
arrows, connections and v2 code. Existing attachments can be preserved, previewed,
exported, duplicated and removed; importing new attachments is outside the initial
scope. This is not full web parity.

Local build/launch comes first. Public distribution, signing/notarization,
updates, and an app store are not first-release requirements.

Editing is keyboard-first with full mouse/trackpad support. Prioritize rapid
thought entry, adjacent thoughts, and keyboard connections without replacing
native text editing or standard Mac commands.

In the planned editor, connected documents autosave to their JSON source; explicit
Save remains available. The viewer implements neither. Recover committed work and
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
The viewer does not establish editable web/native compatibility. Web verification
still runs with `mix check` from the repository root; it does not build or verify
the native app.
