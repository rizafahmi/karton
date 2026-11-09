# Native macOS implementation specification

Status: design specification; the session-only native app supports blank v2 New,
shape/text and standalone line/arrow insertion, connections, object/connection
selection and Tab traversal, movement, resize/rotation and line endpoint editing,
duplication, deletion, front/back stacking, lock/unlock, object/connection style
editing, captions and Undo/Redo. Text edits retain geometry; the full editor,
persistence and acceptance proof remain incomplete.

## 1. Approval boundary and outcome

[TASKS.md](../TASKS.md#final-milestone-independent-native-macos-editor) owns
milestones, approvals, and sequencing. Approved foundation choices are recorded
below; remaining proposals do not authorize tool installation, dependencies,
version-1 JSON changes, or skipping compatibility and runtime proof.

Approved product direction:

- Personal use first: brainstorming, developer diagrams, and Keynote illustrations.
- Create and edit canvases without running the web app.
- Keyboard-first, with complete mouse/trackpad access to the agreed editing tools.
- Autosave connected JSON documents; recover untitled work before choosing a source.
- Independent native UI following Apple Human Interface Guidelines, no webview,
  Phoenix server, BEAM, or bundled web runtime.
- Share JSON contracts/fixtures, not runtime code; preserve v1 files and implement
  the delivered web/shared v2 code-node contract for snippets. Retain metadata,
  authored geometry, semantic font roles, and named colors.
- Transparent high-resolution PNG export for Keynote; no full web parity implied.

Everything labeled proposed below is a recommendation awaiting adoption. The
existing code-snippet requirement remains in the final native milestone; neither
this document nor a working basic canvas removes that requirement. Public
packaging, signing/notarization, an update service, accounts, cloud storage,
multiplayer, and a database are not requirements of the first personal release.

End-to-end outcome: launch locally → New → add thoughts → connect/rearrange →
choose a JSON destination → continue editing with autosave → close/reopen →
open the same file in the web editor → export a transparent PNG for Keynote.

## 2. Proposed implementation decisions

| Decision | Selected or recommended behavior | Approval status |
| --- | --- | --- |
| Language and UI | Swift; AppKit document/window lifecycle, custom canvas and inspectors | Approved 2026-11-05; AppKit inspectors replace the SwiftUI choice |
| Drawing/export | Core Graphics drawing and native text layout shared between canvas and PNG, not screenshots | Approved 2026-11-05 |
| Deployment | macOS 27 for the first personal build; older OS/Intel support requires an explicit target and proof | Approved 2026-11-05 |
| Project | Swift Package plus command-line `.app` bundling under `macos/`; no root build orchestrator or new third-party dependency | Approved 2026-11-05, replacing Xcode-project choice |
| Editable content | Existing v1 shapes/lines/connections plus v2 code; preserve/preview/export/duplicate/remove existing attachments, no new attachment import | Approved 2026-11-05; section 5 coverage requires native proof |
| Autosave | Coalesced completed transactions; request after 5 seconds quiet or within 30 seconds of continuous committed edits while active | Approved 2026-11-05; not a disk-durability deadline |
| Recovery | Native untitled recovery plus private app-owned storage for uncovered committed work and active text drafts; retain until saved elsewhere or explicitly discarded | Scope, request timing, restore/conflict/close choices approved 2026-11-05; storage details need proof |
| PNG | Default 2,048-pixel longest side, proportional other dimension, 32 world-unit padding; configurable size, at most 8,192 pixels per side and 16,777,216 pixels total | Approved 2026-11-05; native/Keynote proof pending |

A basic canvas is not the complete milestone: approved code snippets, agreed
compatibility coverage, persistence failure proof, and actual Keynote proof must
also be delivered. Resolve the decision register in section 9 before the
corresponding implementation work; do not silently treat recommendations as approvals.

## 3. Proposed canvas interaction contract

### Window and command surface

One document model per file identity, with a document window containing a compact
native toolbar, dominant canvas, contextual inspector, and unobtrusive save state.
Opening a second file creates a separate document/window; reopening an already
open file activates its document rather than creating an independent writer.
No web-style document menu, server-path field, project dashboard, or account UI.

Provide native File New/Open/Save/Save As/Close/Export PNG and Edit Undo/Redo,
Cut/Copy/Paste/Duplicate/Delete/Select All. New and Open do not replace another
window's document. Explicit Save As changes the source only after successful
writing; cancelled/failed Save As leaves identity and autosave destination intact.
Do not redirect autosave to an export or recovery file.

Commands appear in menus even when they have canvas shortcuts. Standard menu
commands operate through the responder chain; text fields/editors own their
editing keys. Disable unavailable commands with an understandable reason where
needed. Toolbar and inspector are keyboard-accessible, with native focus and
accessibility names; do not represent the whole canvas as one inaccessible bitmap.
Expose objects/connections and selection through native accessibility elements.

### Canvas shortcuts and focus

Proposed canvas-only shortcuts intentionally reuse familiar web editing concepts,
not browser event handling. They apply only with canvas/object focus, without
marked text, an active field editor, modal sheet, or a conflicting editing mode.

| Action | Proposed interaction |
| --- | --- |
| Select / rectangle / ellipse / diamond / triangle / text / line / arrow | V / R / O / D / I / T / L / A; pointer placement or Enter at viewport center |
| Traverse objects then connections | Tab/Shift-Tab changes focused item, not the selected set; root entry anchors the first selected drawing in stacking order; exit at ends without trapping focus |
| Toggle focused selection | Tap Space; Space held through dragging pans without toggling on release |
| Select / add to selection | Click; Shift-click; marquee for multiple objects |
| Move selection | Arrows by 1 world unit; Shift-arrows by 10; locked objects unchanged |
| Geometry | G enters handles/endpoints; Tab cycles; arrows preview; Enter commits once; Escape restores |
| Edit ordinary text/connection label | Enter or double-click; native text editor; multiline ordinary text uses Enter for newline, Command-Enter/explicit finish to commit, Escape to cancel |
| Adjacent thought | N → cardinal direction → type → Enter adds; Shift-Enter newline; Escape cancels |
| Create/reconnect connection | C → source/side → target/side → Enter commits; Escape cancels |
| Style | S reveals/focuses native inspector; selection changes do not steal typing focus |
| Pan/zoom/fit | Space-drag, trackpad scroll and magnification; +/− zoom with canvas focus; Shift-1 fits; Shift-0 resets |
| History/clipboard/stacking | Native Command-Z/Shift-Command-Z, Command-C/X/V/D, Delete, Command-Shift-]/[ |

Menus define actual shortcuts at implementation; test conflicts with macOS and
input methods. F2 is not required on Mac keyboards. While an inspector field or
text editor is active, letters, arrows, Space, Tab, and clipboard commands belong
to that control. Escape handles its innermost editor/mode/sheet first; it does not
close the document. App deactivation retains pending drafts and does not itself
commit them. Refocusing controls must not change selection, pan, or history.

### Editing transactions and adjacent thoughts

- Separate committed document content from selection, focus, viewport, tool,
  geometry/connection previews, and text drafts. Session state is not document JSON.
- A drag, resize, rotation, connection/reconnection, multiselection style command,
  or thought insertion commits as one named undoable transaction. Undo restores
  IDs, bindings, geometry, metadata, and relative stacking order; redo restores
  the same newly created IDs. No-op/cancel does not clear redo or dirty content.
- Resize along rotated local axes with the opposite anchor fixed. Lines expose
  free endpoints and do not acquire proximity bindings. Connections remeasure
  against actual outlines, including rotated/non-square triangles and self-loops.
- A focused eligible unlocked text-bearing shape supplies N; root-canvas fallback
  requires exactly one selected eligible drawing and no selected/focused edge.
  An adjacent thought is a fresh upright default rectangle, not a metadata clone.
  Proposed web-compatible placement: 160×96 world-unit initial box, 48-unit gap
  beyond rotated bounds, skip occupied bounds along the chosen cardinal ray.
  Text growth rechecks placement; do not move existing objects or infer a link.
- Draft geometry represents full text, not a clipped scrolling editor. Reveal
  enough to type without zooming to fit the whole long draft. Font readiness and
  measurement precede authoring measured growth; text plus growth commits once.
- Ordinary text and thought entry enforce the existing 2,000-grapheme contract
  without truncation, including combining characters and emoji. Cross-language
  fixtures must resolve segmentation differences, not assume UTF-16 length equals
  the Elixir validator's `String.length/1`.
- Explicit Save, Save As, and Export finish valid pending editors/previews before
  taking a snapshot; an invalid draft blocks the operation with its text intact.
  An N chooser with no placed draft cancels. Automatic saving never forces a
  draft/IME composition to commit or serializes an unconfirmed preview.
- Undo in a text editor first follows native text editing. Canvas history applies
  after finishing/cancelling the editor. Do not run canvas shortcuts inside it.

## 4. Proposed autosave and recovery contract

### Model and save state

Maintain a committed content revision, the last successfully written snapshot,
source URL/file identity and byte fingerprint, a document/source generation, and
separate draft/recovery state. A write carries its snapshot revision and generation.
The source fingerprint describes actual bytes, not only modification time.
Use one serialized writer per document, with all windows sharing its model.

Present these distinctions truthfully:

| State | User-visible meaning and action |
| --- | --- |
| Untitled | No original JSON destination; Save chooses one; recovery is not source persistence |
| Pending draft | Text/geometry is not committed to the document; show pending state separately from last source save |
| Changes pending / saving | Latest committed content is not yet acknowledged on disk |
| Saved | Latest committed snapshot matches the acknowledged source; no unresolved source error; drafts remain separately visible |
| Save failed | Retain content/history, show actionable error and Save As/Retry; do not claim Saved |
| Changed/missing source | Pause source writes; preserve local work; offer recovery/copy and explicit reload/destination choice |
| Read-only | Capability or file restriction is explained; autosave and document-mutating commands disabled |

Use NSDocument's autosave-in-place lifecycle, rather than a competing file writer.
The timing target applies to requesting a save of eligible committed changes, not
an assurance against process suspension, storage failure, or power loss. Explicit
Command-S requests an immediate flush; untitled Save presents the destination panel.
Do not write on open, selection, theme/font resolution, zoom, or inspector display.

### Snapshot and atomic write invariants

1. Capture an immutable valid committed snapshot and its revision/source generation
   on the document's model executor. Encode/write off the UI thread after safe
   snapshot capture; do not copy or rescan attachment content on pointer previews.
2. Within the native document's coordinated safe-save path, verify the current
   destination is the expected regular file with the acknowledged identity and
   byte fingerprint. Missing/replaced/external bytes suspend automatic replacement.
   First creation/replacement uses explicit panel confirmation, not a guessed path.
3. Use native safe replacement with a temporary file on the destination filesystem;
   preserve relevant file permissions/attributes. Recheck the external revision
   immediately before replacement. Never route around NSDocument's coordination
   with a second raw writer or nest coordinators in a deadlocking order.
4. A failed write cannot advance source revision, clear errors, discard history,
   or reset newer edits. The original remains intact; remove abandoned temporary
   artifacts where possible and retain recovery if source persistence failed.
5. A successful older snapshot acknowledges only that revision. Edits made while
   writing remain pending and schedule the next snapshot. A completion from an
   old source generation cannot change a new Save As destination or mark it saved.
6. Undo/redo changes committed content and is eligible for autosave, including
   undoing back to an older state. Autosave is not a history action and cannot
   clear/split history. Saving a copy/export is not an undo boundary either.

File coordination only serializes cooperating participants. Phoenix's current
writer and arbitrary external tools do not participate in native coordination.
Fingerprint checks reduce races but do not provide filesystem locking or eliminate
the last check-to-replace race. Document and test this limit; do not promise
cross-editor transactional editing, automatic merging, or power-loss durability.

### External changes and explicit recovery actions

The conflict choices below were approved on 2026-11-05.

External notification triggers revalidation, not silent source adoption. Once a
conflict is detected, stop automatic source writes and retain the current model,
drafts, and history. Do not reload underneath an editor or silently make a
conflicting file the new baseline, even if all earlier local edits were autosaved.

Offer Save As to a different destination, Reload from Disk with explicit local
work discard confirmation (and recovery protection), or Cancel/Keep Editing with
source autosave still paused. Do not implement a one-click force-overwrite path
in this scope. Reopening a deleted path must not recreate it automatically.
A confirmed reload replaces the model and resets incompatible history; merely
showing a conflict does neither. Revalidate a moved file through the document
lifecycle before resuming writes; never redirect to a filename guess.

### Recovery storage, privacy, and lifecycle

Approved recovery scope: use native document draft autosaving for untitled
committed data. Store only additional state not covered by that mechanism in a
private app-owned recovery envelope under the OS application-support directory,
scoped by the eventual bundle identifier. Do not duplicate the committed snapshot
in a second custom store if native draft recovery already preserves it safely.
The envelope is private session data, not a document-format extension or adjacent
sidecar required to open either document version.

- Preserve confirmed active text drafts, their target/base identity, and any
  committed revision not yet safely stored. Recovery is separate from source
  autosave and never commits a preview. Do not persist incomplete marked-text
  composition; disclose that crash recovery covers acknowledged recovery writes,
  not every keystroke. Geometry gestures may be lost before commit.
- Coalesce recovery writes using the approved 5-second quiet/30-second active
  request targets. Use private owner-only storage and atomic replacement. Recovery
  can contain full text attachments and confidential source code; no telemetry,
  network sync, logging of document bodies, or claimed encryption at rest.
- Restore on launch through a recovery choice, not automatic replacement of a
  connected JSON file. Compare the current source with the recorded base first.
  If it differs, restore the draft as a separate untitled document; do not replay
  stale draft changes onto changed objects. If recovery is corrupt, explain it,
  preserve the original file, and allow explicit discard.
- Retain untitled/conflicted/failed-write recovery until successfully preserved
  elsewhere or explicitly discarded. No silent age-based expiry. Remove obsolete
  app-owned recovery after confirmed source preservation with no pending drafts,
  or explicit discard. Do not remove unrelated OS-managed versions/Time Machine data.
- Show recovery-write failures separately from source-write failures: neither
  successful source saving nor successful recovery proves the other succeeded.
- On normal close/quit, finish valid editors and await pending writes. Invalid
  drafts block silently closing; offer return to edit, preserve recoverable work,
  or explicit discard. Untitled content needs destination choice, acknowledged
  recovery retention, or explicit discard. Failed/conflicted writes must not
  close as Saved. Cancelling any sheet keeps content and source identity intact.
- Restore committed content and retained drafts; cross-launch undo history,
  selection, and exact viewport restoration are not promised. Undo remains intact
  for the current open document across all ordinary saves/autosaves.

The restore and close/quit choices above were approved on 2026-11-05.

Recovery location, integration with OS-managed drafts, and cleanup behavior must
be observed on the selected macOS/toolchain combination before this policy is approved
for delivery; archived platform descriptions do not prove modern storage paths.

## 5. Proposed compatibility and editing surface

The [canonical version-1 contract](../README.md#document-format-version-1) remains
authoritative for existing v1 files. The web editor implements the
[shared v2 contract](../shared/CODE_SNIPPETS.md): the common schema plus explicit
`type: "code"` nodes. The native app shows code as plain text only.

The native codec must retain v1 support and source version on ordinary saves.
New canvases use v2. Code nodes cannot be added/pasted into v1; v2 never silently
downgrades when its last code node is deleted. Explicit v1→v2 conversion produces
a separate snapshot with only the root version changed; original source,
baseline, dirty/errors, and history remain untouched. The web command initiates
a download, not confirmed final persistence, and cannot observe the user's final
path. The format/copy policy is settled; native file-panel and persistence UX
must implement that policy without a hidden migration or source replacement.

| Existing content | Proposed native behavior |
| --- | --- |
| Rectangles, ellipses, diamonds, triangles, text | Render; create, select, edit text/style, move/resize/rotate, duplicate/delete, and reorder |
| Standalone lines/arrows | Render and edit box/endpoints/stroke/arrowheads; remain free-standing, without text/font or proximity binding |
| Connections | All documented paths (`bezier`, `smooth`, `step`, `straight`), markers, labels, automatic/named sides, self-loops, reconnection, and connector-style edits |
| Animated connections | Retain animation flag; render its inherited/explicit dash semantics; flowing animation is not required for the first native rendering, and PNG is static |
| Locked nodes | Render/select/inspect; prohibit ordinary geometry/text/style/delete operations on locked objects; provide explicit undoable lock/unlock |
| Appearance/paper | Render document roles and named colors through native mappings; expose default typography and documented paper controls without rewriting omitted defaults |
| Embedded attachments | Render caption card, preserve content/unknown fields exactly, read-only literal source preview and export of embedded UTF-8; no editing of embedded source, execution, markup rendering, or filesystem linking |
| Attachment authoring | Duplicate/remove existing attachments with existing quotas enforced; new native file/drop import is outside the approved initial scope |
| Unknown metadata | Preserve recursively on retained objects; edit only selected properties; do not confuse unknown metadata with an unsupported node type |
| Unsupported version/type/required rendering semantics | Reject with a clear explanation before editing; do not partially load and later autosave a lossy document |
| Known read-only file | Open visibly read-only if fully renderable; Save As may produce a separately editable document only after capability validation |

Native font family/palette mappings may differ from the web UI; store generic
roles and named colors. The native canvas uses the light-first Neo-Acid palette
(`CanvasTheme`: Raw Gallery Plaster `#f7f7f5` background, `#ecece6` surface,
`#0a0b0d` Ebony Ink for `ink` strokes and text on light/highlighter fills, and
`#ffffff` text on `ink` fills) paired with Light Aqua AppKit controls and a
branded Welcome window; transparent Keynote PNG exports use the same canonical
palette.
Opening, measuring, resolving fonts, or switching
system appearance never resizes existing objects or inserts style defaults. If native
text wraps differently, retain authored boxes until an intentional edit; preview
and commit measured growth only during that edit. Include glyph fallback in both
canvas and export, and test the actual mappings before declaring support.

Retain IDs, node array order, bindings, authored corners/geometry, omitted-role
inheritance, and unknown top-level/node/edge/data/paper/appearance metadata.
Avoid a narrow Codable projection that drops fields or converts all numbers through
Double; unknown integers/numbers must retain their JSON numeric meaning, including
large integer metadata. Whitespace/key order need not be preserved. Deleted objects
lose their metadata; new objects get fresh IDs, not inherited source metadata.

Validate duplicate IDs, missing endpoints, dimensions, lock/parent rules, style
values, typography roles, and text as the web contract does. For attachments,
preserve UTF-8 content, BOM, line endings, empty text, and unknown fields; enforce
262,144 bytes per file and 1,048,576 bytes across all copies, including duplicate,
paste, undo/redo, decode, and save. Do not silently truncate or resolve attachment
filenames as source paths. Ordinary geometry previews must not rescan contents.

Connector-style unknown members/unsupported values remain preserved with the
existing rendering fallback. A non-object `connector_style` permits document
retention but refuses connector-style editing visibly and atomically for a mixed
selection; it is not replaced with a fresh object. Preserve `animated` when the
user changes dash. Do not introduce new persisted routing or native UI fields.

### Code snippets: shared contract delivered, native implementation pending

Native snippets remain required by [TASKS: Code snippets](../TASKS.md#later).
They are dedicated blocks, not simply a mono-font shape or attachment preview:
syntax highlighting, automatic language detection plus manual override, literal
Copy code, Enter newline, Tab/Shift-Tab indent/unindent, Escape finishes editing,
and canvas-shortcut isolation. Paste plain source only into an open snippet
editor; no canvas-paste conversion and no code execution.

The implemented [shared code-snippet contract](../shared/CODE_SNIPPETS.md) owns
the v2 schema, language IDs, literal source, capacities, indentation,
overflow/export and explicit version-copy policy. `data.content` retains exact
valid UTF-8, including BOM, TAB, CR/LF/mixed endings and whitespace; other C0/C1
controls and DEL are refused. Limits are 256 KiB per source and 1 MiB across all
copies, independent of attachment quotas. Code cannot carry an attachment or
duplicate source into a caption. Optional `data.language` is a nonempty string;
omission means Auto, and unknown IDs remain stored with plain-text rendering.
Manual choices persist; detection, tokens and themes never enter metadata.

The inventory is Auto, Plain text, Elixir, Erlang, JavaScript, TypeScript, JSON,
HTML, CSS, Shell, Python, SQL, Swift and Rust, using the canonical IDs in the
shared contract. The web implementation uses approved npm-managed Shiki 4.6
fine-grained grammars/JavaScript engine and Highlight.js 11.12 detection, with
conservative Auto fallback to plain text. The approved native candidate is
HighlighterSwift, using Highlight.js through system JavaScriptCore without a
webview. Auto results may differ without rewriting language. A temporary macOS 27
app bundle loaded its resources and returned exact UTF-8 text and multiple colors
for one sample per required language; whitespace, BOM, mixed line endings, empty
and markup-like samples retained exact bytes. Auto returned the sample text, but
detection accuracy, full safety, pinned version and editor/export behavior still
require proof. No dependency has yet been added. HighlightSwift, a different
package, failed to build with missing SwiftUI macro plugins and its source trims
outer whitespace.
Do not fork the schema/inventory or use hidden shape metadata. Native delivery
still requires shared v2 round-trip, v1 compatibility, editor/history/Fit/export
behavior and actual native workflow proof; working web code is not native support.

## 6. Proposed native component boundaries

Names below describe responsibilities, not pre-created classes or packages.

| Component | Owns | Must not own |
| --- | --- | --- |
| Document codec/model | Lossless retained JSON values, validation, IDs/order, capability report, immutable save snapshots | Native view objects, file panels, viewport, resolved colors/fonts |
| Document controller (`NSDocument`) | File identity/revisions, safe autosave/save, recovery integration, document lifecycle, undo manager | A second independent graph/history or raw uncoordinated writer |
| Edit transactions | Validated model mutations, inverse operations, named atomic undo groups | File I/O, autosave acknowledgements, transient pointer frames |
| Canvas view (`NSView`) | Input/responder/accessibility integration, hit-testing, focus/selection, previews, viewport, text editor hosting | Writing JSON or changing source identity |
| Geometry/text renderer | Shape outlines/handles, edge routing, text layout, native palette/font role resolution, render bounds | Persisting resolved appearance, screen-only export geometry |
| Inspector/toolbar | Effective/mixed values and commands applied to eligible selection; AppKit controls | Materializing defaults during observation or bypassing transactions |
| Recovery integration | Retained draft state, source association, restore/discard and private cleanup | Source replacement, automatic merging, document format extensions |
| PNG exporter | Explicit-pixel offscreen rendering of a flushed immutable snapshot | View screenshots, save baselines, paper/grid/selection/editor chrome |

Use the document's undo manager, not a parallel custom history. Start with an
NSDocument-backed AppKit app rather than two competing document systems in
SwiftUI and AppKit. Keep document mutation on one model executor; background work
receives immutable snapshots and returns generation-scoped results. Cache layout
and routing by relevant content/style/geometry; invalidate affected objects rather
than remeasure the whole document or re-decode attachments every pointer frame.
Do not pre-split these responsibilities into distributable Swift packages.

Apple's [document behavior guide](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/DocBasedAppProgrammingGuideForOSX/StandardBehaviors/StandardBehaviors.html)
describes autosave-in-place, untitled drafts, snapshot-before-background-writing,
and document undo. Its [file coordination guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileCoordinators/FileCoordinators.html)
explains NSDocument's coordinator/presenter integration. These are archived
references, not proof of current OS behavior; implementation must check modern
[NSDocument APIs](https://developer.apple.com/documentation/appkit/nsdocument)
and exercise actual lifecycle/error paths. Do not layer manual coordination over
native safe saving without establishing which layer owns it.

## 7. Proposed PNG contract

Export the complete content bounds, including rotated objects, full text, visible
strokes, self-loop curves, labels, and markers, plus the proposed padding. Hidden
selection/hit targets do not enlarge bounds. No paper fill, grid, toolbar, handles,
editor, or inspector pixels. Empty content gives a clear refusal, not an arbitrary
blank artifact. Zero/negative/non-finite dimensions or limits above the proposed
per-side/total-pixel caps are refused before image allocation; never silently
shrink an explicitly chosen output.

The user chooses the longest side or exact output dimensions. Proportional mode
preserves aspect ratio with the other dimension rounded up to at least one pixel;
exact dimensions fit proportionally with transparent letterboxing, never stretch.
Use an explicit-pixel sRGB bitmap with alpha; world-to-pixel transform depends on
snapshot bounds/output only, not viewport zoom, backing scale, or screen DPR.
Resolve actual drawing fonts and fallback glyphs before measuring/rendering. PNG
export uses the same geometry/text render path as the canvas but no UI overlays.

Export flushes valid drafts, then renders the captured snapshot. It does not
change source URL, save acknowledgement, or history; only committing a pending
edit changes content. Edits arriving after snapshot capture are not falsely marked
exported/saved. Cancellation and image/write failures retain the document. Export
is not evidence that a failed source autosave has succeeded.

## 8. Acceptance proof required during implementation

No native acceptance criterion below is satisfied by this specification, current
Mix checks, Node tests, screenshots alone, or an API mock. Use temporary files,
never edit [examples/welcome.json](../examples/welcome.json) as disposable proof.

| Scenario | Observable required result |
| --- | --- |
| Blank-canvas workflow | New, create text/shapes, adjacent thought, connection, pointer rearrangement, undo/redo, choose JSON source, autosave, reopen in native and web; inspect actual saved objects/IDs/order |
| Pending editors | Escape leaves no history/source change; explicit Save/Export commits valid text plus geometry once; invalid/IME draft never serializes as committed content; deactivation retains it |
| Pointer/keyboard equivalence | Both paths reach agreed operations; selection-preserving traversal, Space tap/hold, rotated resize, self-loop/reconnection, inspector focus and native text editing work without shortcut leakage |
| Autosave races | Deterministically delay a write, edit again, complete first write, inspect first bytes and remaining dirty state, then latest bytes; late Save As/closed-document completions cannot adopt another source |
| External writer | Modify/move/delete the temp source through a non-cooperating writer between edits; source writes pause; original external bytes and local content survive; recovery/copy/reload choices work |
| Write failures/close | Exercise read-only directory/file, replacement failure, cancelled panels, recovery failure, and close/quit during pending/failed writes; no false Saved or silent loss |
| Recovery | Terminate after acknowledged recovery write with untitled content, pending text, and conflicted content; relaunch, inspect restored content and unchanged source; test changed source, corrupt recovery, explicit discard and cleanup |
| Portable round-trip | Compare decoded JSON, not only images: unknown metadata, large numbers, geometry/corners, colors/roles, order/IDs, bindings, omitted defaults, and attachments survive unrelated edits in both editors |
| Limits/history | Combining/emoji text boundaries, attachment exact/over limits, duplicate/paste/undo quota enforcement, atomic style collision refusal, lock rules, and no-op redo preservation |
| Code snippets | All agreed languages, detection/override, literal Copy code, indentation, editing-key isolation, undo/redo and cross-editor save/reopen with unrelated content intact |
| PNG artifact | Inspect actual dimensions/color/alpha and bounds at multiple canvas zoom/backing scales; compare stable export content; place PNGs on actual light/dark Keynote slides and check clipping/legibility |
| Runtime independence | Launch built app with Phoenix stopped and without relying on Mix/deps/web assets; repeat New/edit/autosave/reopen/export and supply exact native setup/build/check commands |

### Fixture work, not an existing native test corpus

`shared/fixtures/v1/document.json` and `shared/fixtures/v2/document.json` are
baseline inputs. The additional `v1/compatibility.json` covers five shape kinds,
rotations, a free line, locks, all edge paths/markers (`bezier`, `smooth`, `step`,
`straight`, `arrow`, `dot`, `none`), self-loop and styled/colliding connectors,
Unicode and empty attachment text, and unknown metadata including 64-bit integers.
`v2/code-compatibility.json` covers literal code, mixed line endings/BOM, language
variants and a connected shape. Native `CanvasChecks` and web ExUnit tests exercise
multi-step edits, undo restoration, independent 1 MiB attachment/code quotas,
v1-to-v2 version-copy snapshots, and temporary-file round-trips across both codecs.
Examples remain user documents, not writable regression inputs.

Before editable native autosave, extend coverage and prove both editors for:
all node kinds/styles/corners/typography and omitted defaults; rotated triangles,
free line endpoints; each edge path/marker, labels, self-loops/side bindings,
animation/dash precedence and connector-style collisions; lock/order/unknown
metadata and large numbers; attachment Unicode/BOM/CRLF/empty/byte boundaries and
duplicate quotas; malformed JSON, duplicate/dangling IDs, unsupported types/values;
v2 source/language/byte boundaries and explicit v1-to-v2 copy behavior, including
unchanged v1 saves and failed/cancelled conversions. Include semantic expected edits/unchanged fields,
not just separate native and web copies of sample JSON.
Keep behavioral unit tests deterministic and use real app/native UI proof for
responder, document lifecycle, OS dialogs, recovery, and rendering behavior.

## 9. Remaining decisions and implementation entry gate

Foundation, deployment target, initial content and PNG defaults were approved on
2026-11-05. Session-only native authoring exists; editable file compatibility proof is incomplete.
Establish fixture coverage and round-trip proof before editable saves. Before
corresponding feature implementation, settle detailed recovery storage/cleanup,
other native file operation UX, native font-role mappings and shortcut map. Prove
the approved highlighter candidate before use. New attachment import is outside
the initial scope.
The shared v2 schema, new-v2/existing-v1 policy, explicit version-copy semantics,
language inventory, and web dependencies are settled, not remaining native design
questions. New native dependency/build-tool choices require separate approval.
The web code-snippet prerequisite is implemented; remaining non-native work and
scope/sequencing decisions in TASKS.md still gate native implementation.

The inspected machine has Swift 6.4, macOS 27.0.1 and Apple Command Line Tools.
A temporary Swift Package built for macOS 27, assembled into an `.app`, and
launched through `open -n -W` reported an AppKit window visible. The linker
warned that two Command Line Tools search paths were missing despite successful
build and launch. This is a toolchain probe, not native editor, document handling,
signing, distribution, or test proof. The temporary package was removed.
A minimal SwiftUI `@State` inspector failed to compile with the installed Command
Line Tools because `SwiftUIMacros.StateMacro` was unavailable. A temporary AppKit
inspector handled an injected native mouse event and a model-to-control update.
External automation lacked Accessibility permission; physical-pointer and
accessibility interaction remain unproven.
The native app's actual build and check commands are in [README.md](README.md).
Local ad-hoc bundle signing, strict verification and Launch Services opening have
been exercised. Persistent editing, Developer ID signing, notarization,
distribution and the complete native workflow remain unproven.
