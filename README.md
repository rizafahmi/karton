# Elixir Canvas

A local-file-first spatial thinking canvas built with Elixir, Phoenix LiveView,
and Hakushi. The JSON file is the document, not an export from a database.

## Planned native macOS editor

The next milestone is an independent native Mac editor sharing the version-1 JSON
document contract, with Apple-native UI and transparent high-resolution PNG export
for Keynote. It is not implemented yet and will not require the web app's runtime.
See [TASKS.md](TASKS.md#next-milestone-independent-native-macos-editor) for scope,
acceptance proof, and open repository/technology decisions.

## Run

Requires Elixir 1.18+ and a compatible Erlang/OTP, available through Nix. The
application has no database, account service, or npm installation step. Mix
fetches the dependencies and the esbuild binary used to bundle local assets.

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000>. The initial document is `examples/welcome.json`.
Saving it edits that actual example file. To start with a different file:

```sh
CANVAS_FILE=/absolute/path/to/ideas.json mix phx.server
```

Use **Open…** in the document menu to choose a JSON canvas with the operating
system's file picker. The selected bytes are validated by the same document
decoder as server files. The browser provides a filename, not an absolute server
path; opening a selected file never redirects Save to the initial document or
guesses a path from its name. Cancelled pickers and invalid content leave the
current document intact. Opening another file is blocked while canvas edits or
pending text commits remain unsaved.

On supporting browsers in a secure context (including localhost), the browser's
File System Access handle lets **Save** write the selected file after permission
is granted, and **Reload from disk** reads that handle again. Handles belong to
the current tab; a page/session restart requires opening the file again. Direct
saving requires the native picker plus file-handle read, write, and permission
methods; the document menu explains the available behavior before opening.
Safari, Firefox, and browsers with missing or incomplete support use a genuine
file-input picker instead. This opens a copy: **Save copy** downloads JSON, shows
“Copy downloaded; original file not changed”, and keeps unsaved edits marked
dirty because the app cannot confirm where you saved the download. **Reload:
choose file again…** asks you to reselect the original file; it does not pretend
an in-memory snapshot is fresh disk content.

**Advanced: server file path** retains the explicit server-local workflow. Its
source-path field opens existing files on the machine running Phoenix. The
new-file field creates an empty document at a path whose parent directory already
exists and refuses to replace an existing file. Paths can be absolute or relative
to the server's working directory. These are server paths, not browser-selected
file locations.

**Keep the server local.** It intentionally has access to local files, without
accounts or access controls. Development and production configurations bind to
IPv4 loopback. This is not a hosted multi-user application. See
[SECURITY.md](SECURITY.md) for the trust boundary and file-safety controls.

## Examples

The [`examples/`](examples) directory includes a feature tour and structured
brainstorming boards that you can open from the document menu (**Open…**) or
launch directly via `CANVAS_FILE`:

```sh
CANVAS_FILE=examples/kitchensink.json mix phx.server
```

| File | Description |
| --- | --- |
| [`examples/welcome.json`](examples/welcome.json) | Default startup canvas |
| [`examples/kitchensink.json`](examples/kitchensink.json) | Interactive tour of all shape kinds, named colors, stroke styles, typography roles, rotations, standalone lines, edge paths, self-loops, and locked objects |
| [`examples/livestream_ideas.json`](examples/livestream_ideas.json) · [`_example.json`](examples/livestream_ideas_example.json) | **Collision Lab** — blank template and worked example for mashing specific constraints with general topics |
| [`examples/tree_and_twist.json`](examples/tree_and_twist.json) · [`_example.json`](examples/tree_and_twist_example.json) | **Tree & Twist** — blank template and worked example for four-branch decomposition plus constraint twists |
| [`examples/worst_idea.json`](examples/worst_idea.json) · [`_example.json`](examples/worst_idea_example.json) | **Worst Idea First** — blank template and worked example for inverting deliberately terrible ideas into strong ones |
| [`examples/wrong_genre.json`](examples/wrong_genre.json) · [`_example.json`](examples/wrong_genre_example.json) | **Wrong Genre Only** — blank template and worked example pairing utility software with game mechanics |
| [`examples/ideas.json`](examples/ideas.json) · [`examples/board.json`](examples/board.json) | Minimal starter boards |

## Interface

The editor uses the light Neo-Acid design system: Raw Plaster paper, square-edged
floating controls, crisp black frames, and acid-filled active tools. Hovered tools
stay neutral so the selected tool remains distinct. Cobalt marks object selection
and keyboard focus. Drawing colors and typography resolve through the interface's
theme from portable names; the document retains its authored geometry and style intent.

- **Paper** sits beside the filename at the upper left. The filename opens the
  document menu: native **Open…**, advanced server-path open/create, reload,
  **Default text style**, shortcut help, and project/stack details with a link
  to the GitHub repository.
- **Download** exports an image beside **Save** at the upper right. Save writes
  the selected JSON when possible; **Save copy** explicitly downloads a separate
  JSON copy otherwise. Image Download becomes icon-only on narrow screens.
- Drawing tools and **Style** share the bottom dock, separated by a divider.
  **Line** (`L`) has a plain segment icon; **Arrow** (`A`) keeps its arrow icon.
  A quiet **AgentRouter** credit link sits at the bottom right.
  The inspector opens above the dock, not over the drawing tools. Style becomes
  icon-only on the smallest screens; all eight tool buttons remain visible at 320px.
- Undo and redo stay at the top of the left rail. The live zoom percentage below
  them opens a popover with zoom out/in, Fit to screen, and Reset to 100%.
  Repeated adjustments keep it open; Escape or an outside click closes it.
  Opening the popover does not change zoom, and the percentage also tracks wheel
  zoom while closed.
- Arrangement remains separate below a divider, with tidy-up options beside the
  rail and **Bring to front** / **Send to back** buttons below them. The rail ends
  above the dock and scrolls vertically in short windows.
- Selection alone does not open Style. Escape closes the menus and inspector.
- Unsaved state remains visible under the filename. External changes and save
  failures appear as actionable messages rather than disappearing into a menu.

New files use the generic `sans` typography role. **Default text style** selects
the document default: **Normal**, **Title**, **Code**, or **Handwritten**. In
**Style**, the **Text style** group shows the selected shapes’ current style and
lets them choose an explicit style. Save retains generic roles, not font-family names.
Font families and weights are listed under [Drawing appearance](#drawing-appearance)
and in [DESIGN.md](DESIGN.md#3-typography). A different interface can choose different
families. Text may wrap differently, but opening or changing a typography role
does not resize or reposition authored objects. Fonts are self-hosted; canvas
initialization waits for the resolved drawing font before measuring or editing text.

See [DESIGN.md](DESIGN.md) for the shared design rules, app-specific light-first
adaptation, and implementation details. The actual editor is the design surface,
not a separate visual-study route.

Amatic SC Bold is an unmodified upstream distribution from
[Google Fonts](https://github.com/google/fonts), with its SIL Open Font License
notice in `priv/static/fonts/amatic-sc/OFL.txt`. The five Neo-Acid faces are
vendored from [Fontsource](https://fontsource.org/) packages `@fontsource/unbounded`,
`@fontsource/mona-sans`, and `@fontsource/monaspace-neon`; their upstream SIL Open
Font License notices are included in `priv/static/fonts/neo-acid`.

## Edit

- Use the canvas toolbar for rectangles, ellipses, diamonds, triangles, and text.
  **Line** (`L`) draws a standalone straight segment without arrowheads, even when
  drawn between shapes. Hold **Shift** while drawing to snap its direction to
  45° increments (horizontal, vertical, or diagonal); release Shift to draw freely.
  **Arrow** (`A`) keeps the existing behavior: it connects shapes when drawn
  between them and creates a standalone arrow elsewhere.
  Dragging between shape handles also creates a connected arrow.
  To loop back to the same shape, drag between two different side handles.
  The connected arrow curves outside the shape and returns to its target handle;
  returning to the same handle does not create an edge.
- Select a connected arrow (including a self-loop), then open **Style** to choose
  named stroke color, width 1/2/4, and solid/dashed. Edge-only multiselection applies
  one property to all selected connections in one undo step; different values
  show no pressed option. Mixed node/connection selections retain the node
  inspector, without changing connections. Bindings, labels, routes and existing
  target markers are unchanged. Standalone lines keep their own controls.
- Select a standalone line or arrow to drag either endpoint; the opposite endpoint
  stays fixed. Focus an endpoint and use the arrow keys for precise adjustments.
  An endpoint drag is one undoable edit; Escape or a cancelled pointer gesture
  discards its preview. Locked objects have no editable endpoint controls.
- Double-click a text-bearing shape to edit its text. Select it to resize or
  rotate it; the selection outline, resize handles, and rotation knob follow the
  shape while turning and after release. Resize along the shape's rotated axes;
  the opposite corner or side stays fixed. Escape or a cancelled pointer gesture
  discards the rotation or resize preview. Open **Style** to change its appearance.
- Pan with Space + drag; open the left rail's zoom percentage to zoom or fit the canvas.
- With the canvas or an object focused, Command/Ctrl + `+` (or `=`) zooms the canvas
  in and Command/Ctrl + `-` zooms out. Outside that focus scope—including fields,
  toolbar controls, and the zoom popover—these keys retain browser page zoom.
  Focus any control to enlarge the application chrome with browser zoom.
- Use **Bring to front** or **Send to back** in the left rail to reorder selected
  drawing objects. Selected objects keep their relative order, as do the other
  objects; locked objects are not reordered. Only stacking changes, using the
  version-1 `nodes` array's back-to-front order, without changing geometry,
  appearance, metadata, or connections. Empty selections and selections already
  at the requested extreme leave dirty state and history unchanged.
- Each effective stacking command is one undoable action in the same history as
  ordinary edits; redo restores its order. Hakushi supplies ordinary undo/redo,
  with the local drawing adapter adding stacking entries. Reload resets history.
- Save explicitly with **Save** or **Save copy**, Command-S, or Control-S. Saving
  commits an active shape text editor and waits for Hakushi's resulting changes,
  including automatic text-box growth. Unsaved changes live in memory, not in a
  database. A browser write acknowledgement only clears edits included in its
  serialized snapshot; edits made while writing remain dirty.
- Edit the JSON in an ordinary text editor, then reload it through the document
  menu. Reload asks before discarding unsaved canvas edits. Browser-selected
  copies must be selected again; handle-backed files and server-path files are
  reread from their respective source.

Server-path files are checked once a second. A detected external modification,
removal, or read failure leaves the current canvas intact. Their saves check the
last-read SHA-256 revision even before the next check. Browser-selected handles
are checked when saving or reloading, not polled by the server. Saving hashes the
current selected file before opening its writer and again before closing it;
changed or unavailable sources refuse the write without discarding canvas edits.
Input-opened copies have no live disk handle, so external changes can only be read
by selecting the file again. Invalid content never replaces the open graph.

Server-path saves write and sync a temporary sibling file, preserve permission
bits, recheck the revision, and rename over the source. App saves to that path are
serialized across tabs. Browser-handle saves use an exclusive writable stream;
the file is replaced only after the stream closes successfully. Both are
optimistic checks, **not a filesystem compare-and-swap or a lock respected by
external editors**: an external write racing the final check and replacement is
not excluded. Take turns editing externally; automatic merging is absent.
Server paths refuse symbolic links. Server saves do not preserve extended
attributes or guarantee parent-directory power-loss durability; browser file
permissions and filesystem write behavior are controlled by the browser.
### Keyboard editing

The document menu contains a compact **Keyboard shortcuts (?)** disclosure; **?**
from the focused canvas opens it. Editing stays directly on the canvas—there is
no separate properties or replacement editor panel. Tab/Shift+Tab, Enter/Space,
and native select navigation reach the existing controls. The file menu retains
native open, server open/create forms, reload, default font and project links.
Style remains authoritative for every applicable appearance choice, including
standalone arrowheads; Paper and arrangement retain their native menus.

The following shortcuts require focus on the canvas or an object, not a field,
select, contenteditable editor or toolbar button. IME composition is left alone.

| Action | Keys |
| --- | --- |
| Select; rectangle; ellipse; diamond; triangle; text; line; arrow | V; R; O; D; I; T; L; A |
| Place the active drawing tool at viewport center | Enter |
| Edit selected shape text / connection label | Enter or F2; Escape cancels; blur commits |
| Visit objects then connections without changing selection | Tab / Shift+Tab |
| Toggle focused object or connection / select all objects | Tap Space / Command/Ctrl+A |
| Select nearest object | Alt+arrows |
| Move selected unlocked objects | Arrows (1 pixel); Shift+arrows (10 pixels) |
| Geometry preview on one selected unlocked object | G; Tab cycles handles; arrows preview; Enter commits; Escape cancels |
| Grow an independent thought from a focused or singly selected unlocked text-bearing shape | N; cardinal arrow; type inline; Enter adds; Shift+Enter newline; Escape cancels |
| Pan | Hold Space and drag; with no selection, arrows (Shift for larger steps) |
| Existing Style / compact shortcut reference | S / ? |
| Create / reconnect selected connection | C; arrows or Tab choose; Enter advances/commits; Escape cancels |
| Copy / cut / paste / duplicate | Command/Ctrl+C / X / V / D |
| Delete; undo; redo | Delete or Backspace; Command/Ctrl+Z; Shift+Command/Ctrl+Z or Ctrl+Y |
| Bring to front / send to back | Command/Ctrl+Shift+] / [ |
| Tidy; fit; reset zoom | Shift+L; Shift+1; Shift+0 or Command/Ctrl+0 |
| Canvas zoom | + / −; Command/Ctrl+ + / − |

**Save** (Command/Ctrl+S or the Save button) works throughout the workspace and
commits active shape text, connection labels, geometry previews and placed
adjacent-thought drafts before awaiting server patches. An invalid thought draft
blocks saving rather than writing the old graph and claiming success.
It retains the source-specific Save/Save copy contract above; there is
no fake New or Save As command, nor a browser New/Reload/Find shortcut takeover.
Keyboard activation of a drawing-tool button focuses the canvas for placement.
Command/Ctrl+O invokes the existing native **Open…** workflow from any field;
Command/Ctrl+Shift+E invokes the existing image **Download**. Both retain current
unsaved guards, browser capabilities and cancellation behavior.

**Tab traversal** keeps selection unchanged. The canvas remains a focusable entry
point even when empty. After mouse selection leaves focus on the canvas, the first
Tab **or Shift+Tab** focuses the selected drawing; with multiple drawings selected,
it uses the first live selected drawing in canvas order. Direction applies on
subsequent presses, which visit the next/previous drawing, then connections, and
leave the canvas at the ends without wrapping. An already focused object or
keyboard-focused connection takes precedence over selection.

**G geometry mode** starts at the southeast resize handle. Tab/Shift+Tab cycles
eight resize handles and rotation; standalone lines/arrows instead expose start
and end endpoints. The cobalt square marks the active handle and the existing
announcer names it. Arrows preview 1 pixel or 1 degree; Shift changes the step to
10. Resizing respects the rotated local axes and keeps the opposite anchor fixed.
Enter commits all preview changes as one ordinary undoable action; Escape restores
authored geometry without dirtying or history. Unchanged previews are no-ops.
Save commits first. Open commits before its existing unsaved guard, so a changed
preview cannot bypass refusal. Leaving the canvas or beginning a pointer gesture
cancels; history, clipboard, selection-all and stacking commands cancel before
running. Canvas zoom can preserve the mode. Browser-reserved keys remain native,
and a changed preview participates in the unload warning.

**N adjacent thought** grows from the focused, unlocked text-bearing shape,
even if it is not selected. With focus on the canvas itself and no keyboard-focused
connection, N can instead use exactly one selected drawing, provided no connections
are selected; mouse selection needs no extra Tab. Multiple selected drawings,
selected connections, standalone lines, fields, and active drawing tools cannot
supply this fallback. The same unlocked text-bearing-shape eligibility applies.
Press N, then a cardinal arrow to choose a canvas-world direction and immediately
type in the on-canvas textarea. Enter adds the thought and focuses the new shape,
ready for another N; Shift+Enter adds a newline. Caret keys and shortcut letters
remain text editing inside the textarea. Escape cancels either stage before
closing Style. Explicitly placed blank or whitespace-only thoughts are allowed;
Save cancels a chooser only when no direction has been chosen.

Each new thought is an independent, upright rectangle, initially 160×96 canvas
pixels, with the document's default typography and ordinary unfilled drawing
style. It does not clone the source's type, dimensions, rotation, font override,
colors, locks, or unknown metadata. Source objects remain unchanged. No automatic
connection is inferred from adjacency; use C separately when a link is intended.

Placement starts 48 canvas pixels beyond the source's rotated axis-aligned
bounds, centered on the perpendicular axis. If the new box would overlap another
node's rotated bounds or their 48-pixel clearance, it skips farther along the
chosen cardinal ray. Text growth rechecks that placement; existing nodes and
edges are never moved or rerouted. This is local node-bound avoidance, not
global layout. Pan and zoom do not change the world-coordinate placement.

The preview's full authored height grows to fit measured text at the loaded
document font and 160-pixel wrapping width. The inline textarea scrolls within
the unobscured area beside the rail and between the header and dock. Its nearby
hint/error stays screen-sized. Revealing the draft can pan and reduce zoom only
to fit its width or a minimum editing viewport of one text line, ordinary
padding and the hint; it never zooms in or fits the full long height. The
committed box matches the full preview, not the smaller scrolling editor.

Until commit, the preview and all text are client-only: **Thought draft — not
added** replaces the ordinary save status without dirtying the graph or changing
history. Escape, an external canvas pointer action, tool/history change, explicit
departure from the canvas, or a changed/removed source cancels without leaving a
placeholder or clearing redo. Switching applications/tabs retains the in-memory
draft; unloading warns about pending work. During the add reply the sole editor
is readonly and says **Adding thought…**; it cannot be re-entered as a second
draft. The final text and box are one ordinary undoable add. Undo removes the
whole thought and recovers canvas focus if its focused node disappeared; redo
restores the same identity, geometry and text.

Save commits the latest valid placed draft before writing; Open commits first
and retains its unsaved guard. The existing 2,000-grapheme Shapes limit is an
explicit inline refusal, never truncation: overlong text stays intact, and
Enter/Save/Open cannot silently save an older graph or discard it. Shorten it or
Escape to cancel. Browsers without `Intl.Segmenter` refuse the commit with an
explanation rather than guessing its length. Source-specific Save/Save copy
behavior is otherwise unchanged.

**C connections** defaults to the focused shape and first chooses its source
side. Arrows/Tab cycle Automatic or named sides; Enter advances to target object,
then target side, then commits. A selected connection starts instead at source
object, allowing both endpoints to be reconnected while retaining appearance and
metadata. A self-loop uses the same object and two distinct named sides.
Tab traversal reaches existing connections; tap Space to select one, Enter/F2
edits its label using Hakushi's existing inline editor, and Delete removes it.
Escape cancels a label or G/C/N mode before a second Escape closes Style.

Escape returns file/style panels to their trigger; native popovers retain their
own dismissal behavior. Panels scroll within short/narrow windows rather than
trapping focus. Paper choices remain authored document edits with undo/save.
The keyboard routes do not imply screen-reader certification or native file-dialog
automation across browsers.


## Document format: version 1

See `examples/welcome.json` for a hand-written document. Files use UTF-8 JSON with
three required top-level fields: integer `version: 1`, an ordered `nodes` array,
and an `edges` array. This is an app-owned format based on Hakushi 0.7's graph
serialization, not the JSON Canvas standard.

### Drawing appearance

Optional top-level `appearance` is an object. Its `font`, when present, is a
generic typography role, not a font-family name. A missing object or missing
`font` means `sans`; saving an existing file does not insert appearance metadata
unless you explicitly change the default text style.

| Role | Intent | Current Neo-Acid rendering |
| --- | --- | --- |
| `sans` | Body and general labels | Mona Sans 400; large emphasis 700 |
| `heading` | Display headings | Unbounded 800 |
| `mono` | Code and technical labels | Monaspace Neon 400; large emphasis 700 |
| `handwritten` | Handwritten lettering | Amatic SC 700 |

New files explicitly include:

```json
"appearance": {"font": "sans"}
```

The document role is the default for shapes and connector labels. Text-bearing
shapes may save an explicit `data.font` override. Missing `data.font` inherits the
document role; choosing an object style saves an explicit role. Standalone lines
do not have a typography role. Shape dimensions
and `data.size` remain authored geometry and size. Other appearance metadata is
preserved; unsupported role names and non-object appearance values are rejected.

The interface owns resolved font families and palette values. It does not add a
theme identifier, resolved font name, or hex colors when saving. Another renderer
may interpret the same roles differently; pixel-identical rendering is not part
of the portable JSON contract. PNG exports capture the current rendered appearance.

New graphical objects explicitly record unfilled ink styling, a two-pixel stroke,
sharp rectangle corners, and left-aligned text. Existing authored corners and
styles are preserved, not reset to the creation defaults. The defaults below
describe hand-written JSON that omits style fields.

### Nodes

Every node has a non-empty, stable string `id`; a `type`; numeric `x` and `y`;
positive numeric `width` and `height`; and a `data` object. Coordinates are canvas
pixels at 100% zoom, with x increasing right and y increasing down. Array order
is stacking order, back to front. Optional `locked` is boolean, default false.
Groups and non-null `parent` values are not supported.

Supported types:

- `shape`: `data.kind` is `rect`, `ellipse`, `diamond`, `triangle`, or `text`.
  `data.text` is embedded plain text, defaults to an empty string, and is at most
  2,000 Unicode characters, matching Hakushi's editor limit.
- `shape-line`: a standalone line or arrow. `data.from` and `data.to` are `[x, y]`
  endpoint pairs relative to the node's box; horizontal and vertical segments
  still have positive box dimensions. Line-tool creations explicitly save
  `data.arrow: "none"`; existing arrow values remain unchanged by endpoint edits.
  Standalone lines have no text or font role. Connections between objects belong
  in `edges`.

Style fields in `data` follow the Shapes kit:

| Field | Supported values | Default when omitted |
| --- | --- | --- |
| `fill` | `none`, `ink`, `surface`, `accent`, `gray`, `blue`, `green`, `yellow`, `red`, `violet` | `blue`; text: `none` |
| `stroke` | Same colors as fill | `blue`; text: `none`; lines: `ink` |
| `width` | `1`, `2`, `4` (stroke width, not node width) | `2` |
| `dash` | Boolean | `false` |
| `radius` | `0`, `8` (rectangle corner radius) | `8`; text: `0` |
| `size` | `s`, `m`, `l` | `m` |
| `font` | `sans`, `heading`, `mono`, `handwritten` (text-bearing shapes only) | Inherit document `appearance.font` |
| `align` | `left`, `center`, `right` | `center`; text: `left` |
| `rotation` | Numeric degrees | `0` |
| `arrow` | `end`, `both`, `none` (standalone lines) | `end` |

Named colors resolve through the renderer's palette. Hue names such as `blue`,
`yellow`, and `red` retain their hue intent across themes. `ink`, `surface`, and
`accent` are theme-relative: this interface resolves accent to acid and surface
to a neutral fill. These remain names in the file, not resolved color values.

### Edges

Each edge requires stable non-empty string `id`, `source`, and `target` fields.
Endpoints reference existing node IDs. Optional fields:

- `source_handle`, `target_handle`: handle identifiers, or null for automatic
  attachment. Shapes accept side names such as `right` and `left`.
- `path`: `bezier` (default), `smooth`, `step`, or `straight`.
- `marker`: `arrow` (default), `dot`, or `none`.
- `label`: string or null.
- `animated`: boolean, default false.
- `data`: an application metadata object, default `{}`.

Connected-arrow appearance optionally uses `data.connector_style`:

```json
{"connector_style": {"stroke": "red", "width": 4, "dash": true}}
```

`stroke` uses the named node palette above (including `none`); `width` is `1`,
`2`, or `4`; `dash` is boolean. Omitted members preserve existing edge rendering:
the current ink-like edge color, 2px width, and ordinary solid stroke. Animated
edges retain their legacy flowing dash when `dash` is omitted; explicit `false`
draws solid without clearing `animated` (flow is then imperceptible). Existing
`marker` semantics remain target-only `arrow`, `dot`, or `none`; there is no
standalone arrowhead mapping.

Version remains 1. Older readers preserve this metadata but do not render the
new appearance. Unrelated metadata and unsupported members/values are preserved;
unsupported style values are ignored for rendering. Editing merges only the
chosen property, not a replacement style object. A historical non-object
`connector_style` is preserved and visibly refuses style edits; a selection
containing such a collision is refused atomically. Merely selecting/opening an
inspector does not add defaults or dirty a file.

Self-loop edges use the same node ID for `source` and `target` and distinct named
side handles, for example `source_handle: "right"` and `target_handle: "top"`.
They remain ordinary edges in the version-1 format; no extra node or routing
metadata is required. Their exterior curve is computed by the renderer.

Node IDs are unique among nodes; edge IDs are unique among edges. Duplicate IDs
and dangling connections are errors, not instructions to generate replacements.

Optional top-level `paper` has `background` (`dots`, `lines`, `cross`, or `none`)
and `grid` (integer 4 through 200). Omitted values use the canvas defaults.

Unknown metadata fields at the top level and on retained nodes, edges, and paper
are preserved during saving. Unknown node types or unsupported format versions
are rejected rather than silently dropped. Saving normalizes formatting and may
make implicit Hakushi defaults explicit; it does not preserve source whitespace
or key ordering. Deleted objects and their metadata are removed.

To move or back up a canvas, copy its JSON file. Current documents have no external
assets, hidden storage, or database dependencies. Selection, viewport, and undo
history are session state and are not part of the file.

## Checks

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
node --test test/direct_keyboard_test.mjs
for file in assets/js/app.js assets/js/native_file.js assets/js/rotation_guides.js assets/js/self_loops.js assets/js/direct_keyboard.js; do
  node --input-type=module --check < "$file" || exit 1
done
mix assets.build
```

The permanent tests cover file round-trips, bundled `examples/*.json` schema and
round-trip validation, external changes, competing app saves, metadata retention,
document lettering, deletion, relocation, malformed documents, stable IDs,
permissions, and refusing to overwrite existing files. Selected-file consumer
tests also cover validated content loading, server-path isolation, prepared-save
metadata, snapshot acknowledgements with newer edits, copy-download dirty state,
and stale reload/save rejection.
Stacking regressions cover stable multi-selection ordering, empty/extreme no-ops,
locked nodes, interleaved ordinary edits and undo/redo, redo preservation after
no-ops, and temporary-file save/reload with unchanged object content and connections.
The geometry/reconnect regression protects combined resize/rotation as one
history edit, reconnect/label history, saved geometry and retained node/edge
metadata. Node regressions cover direct selection, preview cancellation,
rotated fixed-anchor math, exact rotation restoration, locks, Space tap versus
held-pointer selection, and preview lifecycle around history/browser keys.
Adjacent-thought regressions cover rotated cardinal placement, blocker clearance
after growth, non-mutating cancellation and stale-source guards, composition and
overlong-draft refusal, chooser Save cancellation, OS-focus state, and a single
editor across pending-reply re-entry. A LiveView consumer regression proves a
2,000-grapheme authored add, one-step undo/redo with stable identity, and temporary
save/reload retaining the source objects and metadata.
These tests do not certify DOM focus or actual pointer panning; use the
real-editor checks below for browser integration.


### Manual browser verification

After [setup](#run), start a separate server from the repository root with a
disposable copy, never the editable welcome source:

```sh
canvas_check_dir="$(mktemp -d)"
cp test/fixtures/document.json "$canvas_check_dir/canvas.json"
printf 'Temporary canvas: %s\n' "$canvas_check_dir/canvas.json"
CANVAS_FILE="$canvas_check_dir/canvas.json" PORT=4001 mix phx.server
```

Open <http://localhost:4001> (or choose an unused port in both places). Exercise
the affected journey and relevant failure cases; not every path is needed for
every change:

1. Edit text or draw using the normal controls. For interface changes, check
   desktop and narrow layouts with the relevant menus or panels open.
2. Save, inspect the actual temporary JSON for the edit, and check that unsaved
   state clears. Reload or reopen the file and confirm the edit survives.
3. Where relevant, cancel a picker, select invalid JSON, or change the temporary
   source externally before saving. Confirm cancellation, invalid content, and
   conflicts preserve canvas edits rather than replacing them or silently saving.
4. For browser-selected direct saves, use **Open…** and the actual native picker
   in a supporting secure-context browser, grant the requested permissions,
   edit, and save. Inspect that selected file on disk and the dirty state; also
   check relevant permission-denial behavior.
5. In a browser without native file-write support, use **Open…** and the actual
   file-input picker, edit, and **Save copy**. Inspect the downloaded JSON and
   confirm the original is unchanged and edits remain dirty. Reselect the original
   when checking reload.
6. For keyboard changes, use the **?** map as the workflow inventory. Place each
   drawing kind without a pointer; edit/commit/cancel text; select arbitrary
   objects and a connection; preview/commit/cancel resize, rotation and endpoints; create a
   distinct-node arrow and self-loop, reconnect and label it. Exercise every
   applicable Style choice (including standalone arrowheads), Paper, all layouts,
   clipboard/history/stacking, pan/fit/reset and source-specific file actions.
   Inspect saved geometry, metadata, connections and dirty state, not just focus
   or event callbacks. Repeat menu Escape/return and field/IME/browser-zoom
   isolation, then Tab through short/narrow windows with panels open.


Stop only this check's server with Ctrl-C in its terminal (follow any shutdown
prompt). Retain any captured evidence you need before removing only this check's
scratch directory, from the same shell:

```sh
rm -r "$canvas_check_dir"
```

Browser automation can exercise real file-input selection and downloaded JSON;
genuine origin-private file handles can exercise direct writes, but **OPFS does
not verify an OS-selected file or its visible permission prompts**. Those require
the manual native-picker check above. Masking an API does not establish Safari or
Firefox compatibility. No automated browser runner is installed by the setup
above. Puppeteer cannot intercept `showOpenFilePicker` dialogs; see its
[documented interception limit](https://pptr.dev/api/puppeteer.page.waitforfilechooser).

Hakushi 0.7.0 is the published Hex release used here. Its optional Issho integration
currently emits an upstream undefined-module warning when compiled without Issho;
this application does not enable collaboration or add that dependency merely to
silence the warning.

Freehand drawing, external Markdown notes, attachments, cloud storage, multiplayer,
agent APIs, and automatic conflict merging are outside this initial slice.

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, architecture
invariants, and pull request checks, and [SECURITY.md](SECURITY.md) for the
local-server security policy.

Released under the [MIT License](LICENSE). Bundled fonts are distributed under
their upstream [SIL Open Font Licenses](LICENSE).
