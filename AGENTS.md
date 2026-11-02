# Agent context

## Product and trust boundary

Elixir Canvas is a local-file-first spatial thinking canvas built with Elixir,
Phoenix LiveView, and Hakushi. JSON files are the actual documents, not database
exports. There is no database in the current application.

The server is local and unauthenticated, with access to the machine's filesystem;
it is not a hosted multi-user service. Keep this trust boundary explicit.
Databases, accounts, cloud storage, and multiplayer are outside the current scope
unless requested, not permanently prohibited directions.

An independent native Mac editor is planned, sharing version-1 JSON rather than
the web runtime. [TASKS.md](TASKS.md) owns milestones, scope, acceptance proof,
and unresolved repository/technology decisions. No native app is implemented yet.

## Architecture map

- [Document](lib/elixir_canvas/document.ex) owns version-1 JSON validation,
  metadata retention, source identity, and server-file persistence.
- [FlightRecorder](lib/elixir_canvas/flight_recorder.ex) writes rotating development
  logs (`tmp/logs/dev.log`), a crash index (`tmp/logs/crashes.jsonl`), and
  self-contained server/client crash reproduction bundles (`tmp/crashes/crash-*.json`)
  containing git SHA, event parameters, stacktraces, and the in-memory version-1 graph.
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
- [connector_styles.js](assets/js/connector_styles.js) extends the existing Style
  inspector for edge-only selections and renders persisted named connector styles.
  Preserve native highlight/hit-target semantics and bounded, state-specific marker
  variants; mixed node/edge selections retain the node inspector.
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
- [native_file.js](assets/js/native_file.js) handles browser file selection,
  native-handle persistence, and copy-download fallbacks.
- [tokens.css](assets/css/tokens.css) holds shared design primitives;
  [app.css](assets/css/app.css) applies workspace and drawing styles.
- [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and
  [LICENSE](LICENSE) define open-source contributor checks, local-server security
  boundaries, and MIT/font licensing.

## Document and data safety

Preserve compatibility with existing version-1 canvas files. Discuss format
changes before implementing them. The canonical schema and round-trip rules are
in [README: Document format](README.md#document-format-version-1).

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

`Document.new/0` returns a blank `:untitled` document without a path or revision.
New canvas flushes drafts/text, then refuses unsaved work or a busy file operation;
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
documents. Names are ephemeral session identity, never version-1 JSON metadata
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

The planned native Mac interface follows Apple Human Interface Guidelines, not
the web Neo-Acid controls or font pairing. It shares the JSON contract's geometry,
named colors, and semantic font roles, not pixel-identical rendering or a runtime.

## Setup and verification

[README: Run](README.md#run) is canonical for the current web app's prerequisites and setup;
no npm installation is required. [README: Checks](README.md#checks) lists the
CLI verification commands and browser-check limits. Mix aliases are defined in
[mix.exs](mix.exs): `mix check` runs the full read-only verification suite, whereas
`mix precommit` formats files and can change the lockfile.

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
