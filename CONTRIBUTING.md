# Contributing to Karton

Karton is a local-file-first spatial thinking board with an independent native macOS
app (`macos/`, Swift/AppKit) and a local web app built with Elixir, Phoenix LiveView,
and Hakushi. Portable `.karton` (JSON) files are the actual documents, not exports
from a database.

## Prerequisites and setup

Requires Elixir 1.18+, compatible Erlang/OTP (available via Nix or
`erlef/setup-beam`), and Node.js 22+ with npm. No database is needed.
`mix setup` installs Hex dependencies, locked npm highlighting dependencies and
the local esbuild binary. Run `mix assets.deps` after npm lockfile changes.

```sh
mix setup
mix phx.server
```

Open <http://localhost:4000>. See [README: Run](README.md#run) for full usage
and persistence details.

## Architecture overview

The [repository layout](README.md#repository-layout) keeps the web app at the
root and reserves [`macos/`](macos/) for the independent native editor. Run the
commands below from the repository root; they verify the web app only.
Versioned contract fixtures live in [`shared/fixtures/`](shared/fixtures/).
Both editors should consume these files directly in their checks, copying them
to temporary locations before writes rather than maintaining divergent copies.
Native setup/check commands will be supplied when the native app is implemented.

- [`ElixirCanvas.Document`](lib/elixir_canvas/document.ex) — Version-1/version-2 JSON
  schema validation, unknown-metadata retention, SHA-256 revision checks, and
  atomic server-file persistence.
- [`ElixirCanvas.FlightRecorder`](lib/elixir_canvas/flight_recorder.ex) and
  [`Mix.Tasks.Canvas.Doctor`](lib/mix/tasks/canvas.doctor.ex) — Rotating
  development logs (`tmp/logs/dev.log`), structured server/client crash bundles
  (`tmp/crashes/crash-*.json` and `tmp/logs/crashes.jsonl`), and the
  `mix canvas.doctor` diagnostic CLI.
- [`ElixirCanvasWeb.CanvasLive`](lib/elixir_canvas_web/live/canvas_live.ex) —
  LiveView workspace coordinating Hakushi graph state, dirty tracking, and
  save/reload flows across server paths, browser file handles, and copy downloads.
- [`ElixirCanvasWeb.DrawingShapes`](lib/elixir_canvas_web/drawing_shapes.ex) and
  [`ElixirCanvasWeb.DrawingTypography`](lib/elixir_canvas_web/drawing_typography.ex) —
  Custom Hakushi shape kit with unfilled Neo-Acid defaults, standalone lines, and
  portable typography roles.
- [`ElixirCanvas.CodeSnippet`](lib/elixir_canvas/code_snippet.ex) and
  [`ElixirCanvasWeb.DrawingCode`](lib/elixir_canvas_web/drawing_code.ex) —
  Literal UTF-8 code validation, independent quotas and the native Hakushi code kit.
  [`assets/js/code_snippets.js`](assets/js/code_snippets.js) coordinates source
  drafts, literal copy, fit, local worker highlighting and file/export flushes.
- [`assets/js/app.js`](assets/js/app.js),
  [`assets/js/connector_styles.js`](assets/js/connector_styles.js),
  [`assets/js/direct_keyboard.js`](assets/js/direct_keyboard.js),
  [`assets/js/native_file.js`](assets/js/native_file.js),
  [`assets/js/rotation_guides.js`](assets/js/rotation_guides.js), and
  [`assets/js/self_loops.js`](assets/js/self_loops.js) — Browser integration for
  font readiness, File System Access handles and copy-download fallbacks,
  connected-arrow styling, direct keyboard editing/help, rotated selection/resizing,
  and exterior self-loop arrows.
- [`assets/css/tokens.css`](assets/css/tokens.css) and
  [`assets/css/app.css`](assets/css/app.css) — Light-first Neo-Acid design
  tokens and workspace styling. Read [DESIGN.md](DESIGN.md) before modifying UI
  components, colors, or typography.

## Core invariants

1. **Preserve version-1 file compatibility.** New documents use v2, while ordinary
   saves retain the source version. Conversion downloads a separate v2 copy,
   never silently upgrades the original. Discuss further schema changes before
   implementing them. Retain unknown metadata on top-level objects, retained
   nodes, edges and paper settings; preserve code source literally.
2. **Keep document styling portable.** Files store generic typography roles
   (`sans`, `heading`, `mono`, `handwritten`) and semantic/hue color names
   (`ink`, `surface`, `accent`, `gray`, `blue`, `green`, `yellow`, `red`,
   `violet`, `none`), never resolved hex values or font-family names. Changing a
   view's theme or font role must not rewrite authored geometry.
3. **Keep persistence modes honest and distinct.** Never infer a server file
   path from a browser-selected filename or redirect its save to the startup
   document. Server paths, browser `FileSystemFileHandle` sessions, and
   `Save copy` downloads have separate save, reload, and dirty-state rules.
4. **Keep dependencies minimal.** Reuse the existing Elixir, Phoenix LiveView,
   Hakushi, and vanilla CSS stack. Discuss new dependencies or build steps
   before adding them.
5. **Do not use `examples/welcome.karton` as a disposable test fixture.** Always
   test saves against temporary copies (see [README: Manual browser verification](README.md#manual-browser-verification)).

## Verification before opening a pull request

Run the full read-only check suite from the repository root:

```sh
mix check
```

This runs formatting verification, compilation with warnings as errors, ExUnit
tests, JavaScript module syntax checks (`assets/js/**/*.js`), Node unit tests
(`test/**/*_test.mjs`), and the static asset build.

For UI or persistence changes, verify behavior in a real browser using a
disposable temporary canvas copy as documented in
[README: Manual browser verification](README.md#manual-browser-verification),
including narrow viewports (down to 320px) and open menus/inspectors.
