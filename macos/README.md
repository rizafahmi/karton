# Native macOS editor

This directory is the home of the planned independent native Elixir Canvas
editor. Repository preparation is complete; no native application, Xcode project,
package manifest, or native build/check command exists yet.

## Boundaries

- The Phoenix web app stays at the repository root with its existing Mix commands.
- The native app must run without Phoenix, BEAM, a webview, or the web asset bundle.
- The editors share the [version-1 JSON contract](../README.md#document-format-version-1)
  and [`shared/fixtures/v1/`](../shared/fixtures/v1/), not a runtime.
- Shared fixtures are checked-in compatibility inputs. Copy them to temporary
  locations before editing or saving; do not maintain native-only copies of the
  same contract fixtures.
- Native UI follows Apple Human Interface Guidelines rather than the web app's
  Neo-Acid styling. Preserve authored geometry, named colors, semantic font roles,
  and unknown metadata across document round-trips.

## Before implementation

[TASKS.md](../TASKS.md#final-milestone-independent-native-macos-editor) owns the
native scope, unresolved decisions, and acceptance requirements. Minimum macOS,
implementation stack, supported editing/content scope, export limits, and
native setup/check instructions remain undecided. The repository layout does not
settle those choices or establish web/native compatibility.

Web verification still runs with `mix check` from the repository root. It does
not build, launch, or verify a native app. Independent native setup and
verification instructions must accompany the implementation here.
