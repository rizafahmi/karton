# Shared code-snippet contract

The web editor supports this version-2 contract. The independent native viewer
shows code as plain text; the native editor must implement the full semantics.
[TASKS.md](../TASKS.md#later) owns delivery status and sequencing. The canonical
format overview is [README: Version 2](../README.md#document-format-version-2).

## 1. Portable representation

Code blocks use `version: 2` and a dedicated `type: "code"` node. They are not
ordinary mono-font shapes, attachment cards, or a hidden v1 metadata extension.
Existing shape/line/edge/paper/appearance semantics remain valid in v2. This is
the app-owned format, not the unrelated JSON Canvas standard.

```json
{
  "version": 2,
  "nodes": [
    {
      "id": "code-example",
      "type": "code",
      "x": 80,
      "y": 80,
      "width": 480,
      "height": 240,
      "data": {
        "content": "defmodule Hello do\r\n\tdef greet, do: IO.puts(\"hello\")\r\nend\r\n",
        "language": "elixir",
        "fill": "none",
        "stroke": "ink",
        "width": 2,
        "radius": 0,
        "size": "m",
        "rotation": 0
      }
    }
  ],
  "edges": []
}
```

| Member | Meaning |
| --- | --- |
| `data.content` | Required UTF-8 source string; empty is valid |
| `data.language` | Optional nonempty UTF-8 string; omission or `auto` selects detection; explicit canonical IDs select a grammar |
| Other node/data members | Unknown metadata, retained recursively on unrelated edits and known-member updates |
| `data.size`, `fill`, `stroke`, stroke `width`, `dash`, `radius`, `rotation` | Existing style value sets; source renders left-aligned in the semantic mono role, not the document default font |
| Node identity/geometry/lock | Existing stable ID, numeric position, positive dimensions, boolean lock, parent and stacking rules |

Code nodes use rectangular outlines and top/right/bottom/left connection handles,
including ordinary connections and self-loops. They cannot carry attachments.
Source is not duplicated into a caption. Rendered token colors, font families,
theme names, parser results, editor selection/scroll positions, filesystem paths,
and browser handles are not document data.

New blocks explicitly write `language: "auto"`. Loading, highlighting, inspecting,
or fitting existing code does not author a language choice. Source-only edits
preserve an omitted or explicit language; changing the language control writes
that chosen member. Known-member edits merge into retained data rather than
replacing it. Unknown language IDs remain stored and display as unsupported
plain text until explicitly changed.

## 2. Literal source and capacities

Load/save/highlight/copy do not trim, normalize Unicode/newlines, expand tabs,
remove a BOM, format source, or insert a final newline. Retain mixed LF/CRLF/CR,
leading/trailing whitespace, empty lines, emoji and combining characters. JSON
escaping, formatting and key order may change; the decoded source must not.

| Limit | Value |
| --- | --- |
| Source per code node | 262,144 UTF-8 bytes (256 KiB), inclusive |
| Source across code nodes | 1,048,576 UTF-8 bytes (1 MiB), including every duplicated/pasted copy |
| Attachment budget | Existing separate 1 MiB aggregate budget; code does not consume or increase it |
| Source characters | Valid UTF-8; TAB, LF, CR and BOM allowed; other C0/C1 control characters and DEL refused |

Ordinary shape text retains its 2,000-grapheme limit. Code source never passes
through that caption editor. Invalid/oversized pending source remains editable
with its error; Save/copy/export cannot silently use the previous source and
report success. The server enforces code quotas on decode/save and on candidate
source/type/add changes, including duplicate, paste and history. Ordinary geometry
changes do not rescan source payloads. A failed addition creates no placeholder
or partial history entry. Changing a code node to an ordinary type is refused;
there is no implicit lossy conversion.

The web textarea presents normalized line separators, but its literal-source
model preserves untouched source segments outside that view. Enter uses the
current line's terminator, then the nearest preceding terminator, then the first
existing terminator, otherwise LF. Paste preserves the Unicode string exposed by
the clipboard API, not unavailable OS clipboard formats. Token output is display
state only and cannot replace canonical source.

## 3. Languages and highlighting

| UI choice | Canonical ID |
| --- | --- |
| Plain text | `plaintext` |
| Elixir | `elixir` |
| Erlang | `erlang` |
| JavaScript | `javascript` |
| TypeScript | `typescript` |
| JSON | `json` |
| HTML | `html` |
| CSS | `css` |
| Shell | `shell` |
| Python | `python` |
| SQL | `sql` |
| Swift | `swift` |
| Rust | `rust` |

`auto` is a selection mode, not a grammar. Plain text suppresses detection.
Automatic detection is limited to this curated set and reports uncertainty as
plain text. The web detector requires relevance of at least 3 and a best score
at least 1.25 times its runner-up; ambiguous JavaScript/TypeScript need not be
classified confidently. Explicit language choices transfer exactly between apps;
Auto results can differ between engines without rewriting the document.

The web worker uses npm-locked Shiki 4.6.0 ecosystem modules for highlighting and
Highlight.js 11.12.0 only for detection. Fine-grained grammars and GitHub light/dark
themes are bundled locally with Shiki's JavaScript regex engine; no Oniguruma WASM,
runtime CDN request, remote detection, or editor framework. Canonical `shell` maps
to Shiki `shellscript` and detector `bash`; detector `xml` maps back to `html`.
Ink-filled blocks use dark token colors; other fills use the light palette.

Worker requests/results are scoped to document generation, DOM identity and
source revision. Native DOM rereads may replace JS node objects without changing
the source: those are not new revisions. Cached rendering is idempotent, and
deleted/replaced elements cannot receive an old result. The main thread constructs
safe token text spans; source HTML is never inserted as executable markup. Failure
is visibly unavailable, not misreported as successful highlighting. Detection,
syntax tokens, confidence, resolved colors and engine versions are not persisted.

See [asset manifest](../assets/package.json), [lockfile](../assets/package-lock.json),
and [distributed notices](../priv/static/licenses/code-highlighting.txt).
`mix setup` installs the locked npm tree; `mix assets.deps` refreshes it after a
lockfile change. The existing esbuild build emits the separate worker. Dependency
updates must retain notices for the packages and selected grammars/themes. Native
highlighting remains a separate implementation decision, not permission to embed
the web runtime.

## 4. Editing, history, and export

Use the explicit Code command to open a draft immediately, or select the native
Code tool and click for default-sized placement / drag to choose a box.
Native zero-sized click geometry receives usable dimensions before opening the
source draft; dragged dimensions are retained. V1 tool activation stays in pointer
mode and shows visible guidance with a Document menu action for conversion/New,
not only a screen-reader announcement. Neither path silently upgrades a source.
Source stays local until a valid finish adds the final node once through Hakushi.
Cancel before insertion leaves no node, dirty change, or cleared redo. Empty
source can be deliberately committed. Enter/F2, double-click, or Edit source
opens an existing block's dedicated editor. Locked/read-only nodes cannot be
edited; locked source/box edits are also refused by the server event.

| Action in source editor | Result |
| --- | --- |
| Enter | Insert literal newline; never finish or create another node |
| Tab / Shift-Tab | Indent by two spaces / remove one leading tab or up to two spaces per affected line |
| Escape / Finish | Commit valid source/language/optional fitted geometry in one graph transaction |
| Cancel | Discard the local editor draft |
| Fit to content checkbox | Choose whether the next valid finish also fits the box; toggling alone never commits, Cancel discards the choice |
| Command/Ctrl-Enter | Move focus to language/actions, providing a keyboard exit when Tab indents and invalid source prevents finishing |
| Undo/Redo | Undo literal editor changes before ordinary canvas history |
| Copy code | Copy the entire current literal source/draft, without markup, fences, captions or line numbers; show failure honestly |
| Save / preservation copy / version copy / image export | Finish valid pending source before snapshot; invalid/composing/refused source blocks the operation and remains editable |

A selection ending at the next line's column zero does not indent that next line.
Canvas letter/geometry/connection/clipboard shortcuts do not leak into source or
IME composition. Source controls disable browser spelling/case correction. App
switching retains the in-memory draft. Explicit finish and committed box growth
share native history; there is no second graph undo stack. A language change is
undoable, detection is not. Source-only edits and Fit preserve retained metadata
and the existing language choice.

In the web source editor, Copy is a separate utility on the left. Cancel precedes
the primary Finish on the right, in visual and keyboard order. Fit to content is
a native checkbox, unchecked for each editor session and never saved as metadata.
Its pending choice participates in file flush guards; source and requested fitted
geometry commit together, while unchecking retains authored geometry.

Canvas paste retains existing graph clipboard behavior; pasting plain source
outside an open snippet editor does not create a block. No source execution,
file-link synchronization, automatic formatting/indentation, folding or terminal
output is implied. The web app retains explicit-save/source-mode behavior; native
autosave/recovery remains specified separately in [macos/SPEC.md](../macos/SPEC.md).

Opening/highlighting does not resize authored boxes. Oversized source scrolls in
the authored viewport with a visible overflow indication. The block's Fit to
content button, or finishing with the editor's fit checkbox checked, measures
full source and updates geometry undoably without changing source. Image export
refuses hidden source, including blocks culled outside the
viewport. Native Download handles expected refusals as visible feedback rather
than retrying them as SVG or reporting them as client crashes. Direct export API
calls reject. Controls/status are visually hidden in exported output; this is not
a claim that their markup is removed from serialized SVG XML.
Image export waits for resolved drawing fonts and current-source highlighting
or explicit plain-text fallback before capturing output. Stale worker replies
cannot mark newer source ready; a replaced document refuses the pending export.

## 5. Versions and separate-copy conversion

| Operation | Behavior |
| --- | --- |
| New canvas / server Create | Version 2 |
| Open/edit/save existing v1 | Remains v1; no code-node injection, automatic upgrade, or rewriting of user documents |
| Open/edit/save v2 | Existing types plus code; remains v2 after deleting the last code node |
| Old v1-only app opens v2 | Rejects unsupported version, even when the v2 file has no code |
| Unknown version/type | Clear refusal, no partial editable load or silent omission |

A v1 canvas must be explicitly converted before code can be added or pasted.
Convert to version 2 copy captures validated current content, changing only the
canonical snapshot's top-level version, and initiates a separate JSON download
with a `-v2.json` suggestion. Source IDs/order/bindings/geometry/attachments/unknown
metadata survive. Invalid pending editors block conversion. This is not Save As,
source promotion, an original-file save, or implicit code insertion.

The original stays v1 with its source/revision, comparison baseline, dirty/conflict
state, unresolved source errors, history and newer edits intact. Only finishing a
pending editor can change its graph. Token/generation/busy checks still apply.
The browser controls the download's final path/name: choose a distinct destination;
the app cannot verify manager completion/cancellation or prevent a user-selected
overwrite there. It never writes through the connected original handle/server
path for conversion. Report download initiation only. Explicitly Open the actual
v2 copy afterward; existing unsaved-work guards remain in force.

No silent downgrade or lossy v2-to-v1 export is provided. Historical arbitrary
`data.code_snippet` metadata on an ordinary shape remains opaque metadata, not an
alias for a code node or a migration path from an unshipped proposal.

## 6. Verification boundary

Shared fixtures live in [`fixtures/v1/`](fixtures/v1/) and
[`fixtures/v2/`](fixtures/v2/). Use temporary copies for writes. Useful regressions
cover literal source boundaries/mixed terminators, native atomic source/history,
source-only metadata retention, quota/lock refusals, stable-DOM rereads, real saved
bytes, version retention and separate-copy token/generation/source safety.

Current automated checks and web smoke do not certify native behavior. Native
completion still requires actual v1/v2 round-trips in both apps, native recovery/
file-dialog/lifecycle proof, agreed language highlighting, and actual PNG/Keynote
acceptance. Browser clipboard/IME/picker/cross-engine claims require direct proof;
synthetic events and Node tests alone are not certification.
