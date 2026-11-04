# Native macOS editor

This directory is the home of the planned independent native Elixir Canvas
editor. Repository preparation is complete; no native application, Xcode project,
package manifest, or native build/check command exists yet.

## Boundaries

- The Phoenix web app stays at the repository root with its existing Mix commands.
- The native app must run without Phoenix, BEAM, a webview, or the web asset bundle.
- The editors share JSON contracts and fixtures, not a runtime. Preserve the
  [version-1 contract](../README.md#document-format-version-1) and the
  [version-2 contract](../README.md#document-format-version-2), using both
  [`shared/fixtures/`](../shared/fixtures/) versions. The web app implements
  explicit code nodes and version-copy migration in the
  [shared contract](../shared/CODE_SNIPPETS.md); native support remains pending.
- Shared fixtures are checked-in compatibility inputs. Copy them to temporary
  locations before editing or saving; do not maintain native-only copies of the
  same contract fixtures.
- Native UI follows Apple Human Interface Guidelines rather than the web app's
  Neo-Acid styling. Preserve authored geometry, named colors, semantic font roles,
  and unknown metadata across document round-trips.

## Agreed product direction

The first native release is for personal use. It supports creating and editing
canvases, not just opening boards authored in the web app: New → shapes/text →
connect/rearrange → autosave JSON → export for Keynote. It must be useful without
launching the web app. Detailed tool/content coverage remains a planning decision;
this is not a commitment to full web parity.

Local build/launch comes first. Public distribution, signing/notarization,
updates, and an app store are not first-release requirements.

Editing is keyboard-first with full mouse/trackpad support. Prioritize rapid
thought entry, adjacent thoughts, and keyboard connections without replacing
native text editing or standard Mac commands.

Connected documents autosave to their JSON source; explicit Save remains
available. Untitled documents need recovery before choosing a source. Autosave
must retain undo history and preserve edits/source on write failure or external
conflict, not silently overwrite external changes. Timing, recovery storage and
retention, and detailed close/quit behavior remain decisions in TASKS.md.
The web app's explicit-save behavior is unchanged.

## Before implementation

Read the [implementation specification](SPEC.md) for proposed canvas interactions,
autosave/recovery rules, compatibility coverage, native component boundaries,
export limits, and acceptance scenarios. Its decision table distinguishes
recommendations from approved direction; writing the spec does not authorize
project creation or supersede TASKS.md sequencing.

[TASKS.md](../TASKS.md#final-milestone-independent-native-macos-editor) owns the
native scope, unresolved decisions, and acceptance requirements. Minimum macOS,
implementation stack, detailed editing/content coverage, autosave/recovery policy,
and export limits have concrete recommendations in SPEC.md but remain unapproved.
Native setup/check instructions must accompany implementation. The repository
layout and specification do not establish web/native compatibility.

Web verification still runs with `mix check` from the repository root. It does
not build, launch, or verify a native app. Independent native setup and
verification instructions must accompany the implementation here.
