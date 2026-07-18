# incomm

**Inline, line-anchored code-review comments designed for AI-agent workflows.**

A human attaches a comment to specific line(s) of any file inside the JetBrains
IDE. An AI agent reads those comments through a CLI, does the work, and replies —
and the reply shows up **inline in the editor, right under the line**. The agent
can also leave its **own** comments on specific lines during a review. Everything
is stored in one JSON file both sides share.

```
┌────────────────────────┐        <project-root>/.incomm/notes.json        ┌───────────────────┐
│  IntelliJ plugin        │  ───────────────  read / write  ─────────────▶ │  CLI  (binary     │
│  (Kotlin) — the human   │ ◀───────────────  read / write  ─────────────  │  `incomm`, Go)    │
│  adds/answers inline    │        (atomic writes, last-write-wins,        │  the AI agent      │
└────────────────────────┘         plugin live-reloads on change)          └───────────────────┘
```

---

## 1. What this repo contains

| Part | Path | Language | Who uses it | Purpose |
|------|------|----------|-------------|---------|
| **IntelliJ plugin** | `plugin/` | Kotlin (Gradle) | the human | Add/browse/reply/resolve/edit/delete comments on lines, GitHub-review style, fully inline in the editor. |
| **CLI** | `cli/` | Go (cobra) | the AI agent | List/read/add/reply/resolve/remove comments and edit anchors programmatically; emits `--json`. |
| **Shared spec** | §11 (this README) | — | both | The **single source of truth**: JSON schema + the anchoring algorithm. Both sides implement it identically. |
| **Fixtures** | `fixtures/` | — | both test suites | Shared sample data proving schema/anchoring parity across Kotlin and Go. |

The plugin and CLI are **independent builds** that only agree on the shared spec
(§11) and the on-disk file. The Go CLI is intentionally **not** part of the Gradle build.

```
incomm/
├── README.md                 # this file (incl. §11: data format + anchoring spec)
├── build.gradle.kts          # root aggregator (config lives in :plugin)
├── settings.gradle.kts       # includes :plugin only; Go CLI is standalone
├── gradle.properties         # platform version (IC 2024.2.5), sinceBuild 242, coordinates
├── fixtures/                 # base.txt, cases.json (anchoring), notes.sample.json
├── plugin/                   # IntelliJ plugin (see §6)
│   ├── build.gradle.kts      # Kotlin 2.0.21 + IJ Platform plugin 2.18.1, JDK 21 toolchain
│   └── src/main/kotlin/dev/incomm/…
└── cli/                      # Go module `incomm` (see §5)
    ├── main.go
    ├── cmd/                  # one file per cobra command
    └── internal/{model,store,anchor}/
```

---

## 2. Core concepts (read this first)

- **A "note" is a thread.** It has an original comment plus zero or more replies.
  Fields: `id`, `file` (project-root-relative, `/` separators), `startLine`/`endLine`
  (1-based inclusive), `content`, `author` (`user`|`agent`), `resolved`, `orphaned`,
  timestamps, `anchor`, `replies[]`. See §11 for the exact JSON.
- **Storage:** everything lives in `<project-root>/.incomm/notes.json`. Writers use
  **atomic writes** (temp file + rename). Model is **last-write-wins**, reconciled by
  reload. The plugin watches the file and live-reloads on external (agent) writes.
- **Anchoring:** comments stay attached to the right line even as files change, via a
  best-effort text anchor (prefixes + context + checksum). Positions are recomputed
  (reindexed) **live** on every file change — in the plugin as you type, and in the CLI
  via `reanchor`/`list`. If re-anchoring can't place a note confidently it's marked
  `orphaned`; an agent that knows where its edit landed can fix it with the low-level
  `anchor` CLI commands. The algorithm is specified in §11 and implemented **identically**
  in `Anchoring.kt` (Kotlin) and `internal/anchor` (Go); the shared fixtures enforce parity.
- **Authors & colors convention:** `user` = **blue**, `agent` = **green** throughout the
  UI; a note's state is colour-coded too (open = blue, resolved = green, orphaned = red).
  All colours come from the active IDE theme (`ui/IncommColors.kt`) — never hard-coded.
  Only `user`-authored comments are editable in place (agent comments can be
  deleted/replied-to but not edited by the human).
- **No default keyboard shortcuts.** Every plugin action is user-assignable via
  *Settings | Keymap* and discoverable in **Find Action** (⇧⌘A / Ctrl+Shift+A).

---

## 3. Build & run

### Plugin (requires **JDK 21**)

> **Critical gotcha:** Kotlin 2.0.21 (used to match the 2024.2 platform) cannot parse a
> newer *host* JDK. The Gradle build pins a **JDK 21 toolchain**, but you must run Gradle
> with a JDK it can start from. Always invoke Gradle with `JAVA_HOME` pointed at JDK 21:

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 21)   # macOS; or any JDK 21 path
./gradlew :plugin:runIde         # launch a sandbox IDE with the plugin
./gradlew :plugin:buildPlugin    # distributable ZIP -> plugin/build/distributions/
./gradlew :plugin:test           # run the test suite (headless IDE fixtures)
./gradlew :plugin:verifyPlugin   # JetBrains plugin verifier (IC 242–252)
```

- Platform: **IntelliJ IDEA Community 2024.2.5** (`platformType=IC`), `sinceBuild=242`,
  `untilBuild` open. Uses only **platform-generic** APIs so it works in all JetBrains IDEs.
- Test framework: `TestFrameworkType.Platform` + JUnit4. Tests run headless IDE fixtures
  (`BasePlatformTestCase`) on the EDT.
- Gson is provided by the platform (no extra dependency). Kotlin stdlib is provided by the
  platform too (`kotlin.stdlib.default.dependency=false`).

### CLI

```bash
cd cli
go build -o incomm .    # build the binary
go test ./...           # run tests
go vet ./...
```

---

## 4. The agent workflow (the whole point)

An agent that lands in a repo should:

```bash
incomm skill path            # writes ~/.config/.incomm/SKILL.md, prints its absolute path
```

`SKILL.md` (generated by the CLI itself, see `cli/cmd/skill.go`) is the agent-facing
instruction sheet. Load it, then:

```bash
incomm list --unresolved --json     # 1. what did the human flag?
incomm show <id> --json             # 2. read one thread in full
# 3. do the work…
incomm reply <id> -c "Fixed: streams the file now."   # 4. answer (shows inline in IDE)
incomm resolve <id>                 # 5. mark handled
# …or leave your own review remark on a line:
incomm add -f src/app/main.go -l 42 -c "This ignores the error."
incomm add -f src/app/main.go -l 42:48 -c "Extract into a helper."   # a range
```

---

## 5. CLI reference (`cli/`)

Go module `incomm`, cobra-based, one command per file in `cli/cmd/`.

**Global flags** (persistent):
- `--root <dir>` — project root; default = CWD, walking **up** to find an existing `.incomm/`.
- `--json` — machine-readable output. Agents should always pass this.

| Command | Purpose |
|---------|---------|
| `list [--file F] [--unresolved] [--json]` | List comments (re-anchors first). `--json` → `{ "notes": [Note,…] }`. |
| `show <id> [--json]` | One comment + its full thread. |
| `add -f FILE -l N\|N:M -c TEXT [--author user\|agent]` | New comment on a line/range. `--author` defaults to `agent`. |
| `reply <id> -c TEXT [--author …]` | Reply to a thread. Defaults to `agent`. |
| `resolve <id>` / `unresolve <id>` | Mark done / reopen. |
| `rm <id>` | Delete one comment. |
| `clear` | Delete ALL comments (removes `notes.json`). |
| `reanchor [--file F]` | Recompute line positions from anchors (self-heal after edits). |
| `anchor get <id> [--json]` | Print a comment's current position + anchor fields. |
| `anchor set <id> [--line N\|N:M] [--start-prefix …] [--end-prefix …] [--context-before …] [--context-after …] [--checksum …] [--orphaned] [--no-recompute]` | Low-level: set a comment's final position and/or edit anchor fields. `--line` recomputes the anchor from the file and un-orphans (unless `--no-recompute`). |
| `anchor recompute [--id X] [--file F]` | Regenerate anchor text from the file at each comment's current lines (no move); un-orphans on success. |
| `skill path` | Write `~/.config/.incomm/SKILL.md`, print its absolute path (plain, nothing else). |

**Internals** (`cli/internal/`):
- `model/` — the JSON types (`NotesFile`, `Note`, `Anchor`, `Reply`), `NewID`, `NowUTC`. JSON
  tags MUST match §11 / the Kotlin model.
- `store/` — locate root (`Open`), `Load`/`Save` (atomic), `Clear`, `RelFile`/`AbsFile`,
  `ReadLines`, `SplitLines`.
- `anchor/` — `Compute`, `Reanchor`, the scoring algorithm from §11.

---

## 6. Plugin architecture (`plugin/src/main/kotlin/dev/incomm/`)

Everything hangs off two project-level `@Service` singletons (light services, no XML
registration): **`NotesService`** (data) and **`IncommEditorTracker`** (editor wiring).

### 6.1 Data / storage — `store/` + `model/` + `anchor/`

- **`store/NotesService`** — `@Service(PROJECT)`. Owns the in-memory model and all
  reads/mutations; persists to disk on a single background thread (serialized, atomic);
  publishes `IncommNotesListener.TOPIC.notesChanged()` after every change.
  Key methods: `allNotes`, `notesForFile`, `hasNotesForFile`, `find`, `isEmpty`, `hasNoteOnLine`,
  `addNote`, `updateContent`, `addReply`, `updateReply`, `removeReply`, `setResolved`,
  `updatePosition`, `applySavedPositions`, `removeNote`, `removeNotesForFile`, `clearAll`,
  `reanchorAllFromDisk`, `reanchorFilesFromDisk`, `reload`, `notesPath`, `flushWrites` (test hook).
- **`store/NotesStore`** — disk IO for a base path: load/save (temp+rename), clear, readLines.
- **`store/IncommPaths`** — `relPath(project, vf)` and `findVirtualFile(project, rel)`.
- **`store/IncommNotesListener`** — message-bus topic (`notesChanged`).
- **`store/NotesFileWatcher`** — `AsyncFileListener`; reloads the model when the agent/CLI
  writes `notes.json` externally → drives **live** UI refresh.
- **`store/IncommSourceFileWatcher`** — `AsyncFileListener`; reanchors a file's notes from disk
  when its **source** changes outside the IDE (agent/CLI code edits) and it isn't open in an editor.
- **`model/Notes.kt`** — `NotesFile`, `Note`, `Anchor`, `Reply`, `AUTHOR_USER`/`AUTHOR_AGENT`,
  `newId`, `nowUtc`. Mirrors the Go `model`.
- **`anchor/Anchoring.kt`** — `compute`, `reanchor`, `splitLines`. Mirrors the Go `anchor`.

### 6.2 Editor integration — `editor/`

- **`IncommEditorTracker`** — `@Service(PROJECT)`, the hub. On `start()` (idempotent) it:
  attaches per-document **gutter icon** highlighters (shared `DocumentMarkupModel`, so they
  appear in every split and track edits via `RangeMarker`); creates per-editor controllers;
  subscribes to `notesChanged` → `refreshAll` (whole operation wrapped in a viewport keeper);
  **reindexes positions live** — a debounced `DocumentListener` recomputes and persists each
  note's line as you add/remove lines or edit the anchored text (and on save); registers the
  `NotesFileWatcher` (external `notes.json` writes) and `IncommSourceFileWatcher` (external
  source edits for files not open). Position-only updates persist **quietly** (see §7).
  Holds two pieces of view state:
  - `inlaysVisible` — global show/hide of all inline cards.
  - `hiddenNotes` — set of individually collapsed thread ids (**single source of truth** for
    "this card is hidden"; used by gutter-icon toggle, resolve-auto-hide, and the
    hide-resolved bulk action).
  Public API used by actions/UI: `toggleInlaysVisible`, `toggleNoteHidden`, `isNoteHidden`,
  `setNoteHidden`, `setNoteResolved` (resolve **and** collapse), `hasResolvedNotes`,
  `anyResolvedVisible`, `setResolvedHidden`, `startInlineReply`, `startInlineAdd`,
  `startInlineEdit`, `setHoveredNote`.
- **`NoteInlayController`** (per editor) — renders each note as an **interactive**
  `NoteCardComponent` embedded as a *component inlay* via
  `EditorEmbeddedComponentManager` (full width, shown above the note's first line). Rebuilds
  **incrementally/reconciling** (keeps unchanged cards in place, only adds/removes/updates
  what changed) so the page doesn't churn. Also owns the inline **composer** for add/reply
  and the reveal-then-edit flow. Wraps every inlay mutation in a scroll keeper (see §7).
- **`NoteRangeHighlighter`** (per editor) — colours the **gutter band** over a note's line
  range: when the caret is inside the range, and (driven by the card via `setHoverNote`)
  when the card is hovered. Uses `LineMarkerRendererEx` with `Position.CUSTOM`.
- **`AddGutterController`** (per editor) — the transient **"+"** affordance on the hovered /
  caret line when that line has no note (GitHub-style).
- **`IncommFileEditorListener`** — starts the tracker on first file open (belt-and-suspenders
  vs. the startup activity).

### 6.3 UI — `ui/`

- **`NoteCardComponent`** — the interactive inline card embedded in the editor. Top-right
  toolbar (resolve/reopen · reply · delete); per-comment **hover** reveals edit (user-only) +
  delete icons and lightens the bubble background; in-place edit via a real embedded
  `EditorTextField`; a small `L<start>–<end>` range badge.
- **`NoteThreadComponent`** — the interactive thread used in the **explorer's right pane**.
  Shows a **syntax-highlighted code preview** at the top (single-line note → line ±1 context =
  3 lines; multi-line → the range itself, capped at 7 lines; the note's line(s) highlighted with
  the editor's active caret-row colour), then the toolbar and bubbles. In-place edit uses
  `ThreadUi.flatEditor` (a flat `JBTextArea`).
- **`NotesExplorerPopup`** — the two-pane fuzzy explorer (action *Incomm: Show Comments*).
  Search-Everywhere-style header: search field + **"Include orphaned"** (default **on**, toggle
  **⌘O / Ctrl+O**) and **"Include resolved"** (default off, toggle **⌘R / Ctrl+R**) checkboxes.
  Left = list (`NoteListCellRenderer`, two-line rows; orphaned rows tinted red, resolved rows
  green — both shown side by side when a note is both); right = `NoteThreadComponent`. Typing
  anywhere in the list refocuses the search (like Settings); ↑/↓ navigate, ↵ opens the file
  (caret at the first non-blank column via `IncommNavigator`).
- **`IncommColors`** — the **single source of truth for every colour**, all resolved from the
  active IDE theme (`JBUI.CurrentTheme.Banner` semantic palette + editor scheme); nothing is
  hard-coded. Author/state mapping: user/open = blue (info), agent/resolved = green (success),
  orphaned = red (error).
- **`ThreadUi`** — shared visual language built on `IncommColors`: `roundedCard`, `flatEditor`,
  `authorLabel`, `iconButton`, helpers. Used by cards/threads/composer so they look identical.
- **`NoteGutterIconRenderer`** — per-note gutter icon (open/resolved/orphaned). **Click toggles
  that one thread's card** (hidden ↔ shown); the icon always stays. Orphaned-but-unresolved notes
  float to **line 1** (their real anchor is lost); orphaned-and-resolved notes are hidden entirely.
- **`AddPlusGutterIconRenderer`** — the "+" icon; click starts an inline add composer.
- **`NoteListCellRenderer`**, **`IncommIcons`**, **`IncommNavigator`** — explorer rows, icon
  loader, and file-open-and-jump (caret before first non-whitespace char).

### 6.4 Actions — `actions/` (registered in `plugin.xml`, text in `messages/IncommBundle.properties`)

Contextual (editor + gutter popup; enabled only when relevant; dynamic text where noted).
`CaretNote.of(project, editor)` is the shared "note under the caret" lookup.

| Action id | Text | When enabled |
|-----------|------|--------------|
| `incomm.AddComment` | Add Comment | file present; uses selection range or caret line |
| `incomm.Reply` | Reply to Comment | caret in a note's range |
| `incomm.EditComment` | Edit Comment | caret in a **user**-authored note |
| `incomm.ResolveThread` | Resolve/Reopen Comment | caret in a note (resolve also hides card) |
| `incomm.ToggleThread` | Hide/Show Comment | caret in a note |
| `incomm.DeleteThread` | Delete Thread | caret in a note (no confirmation) |

Tools-menu / global:

| Action id | Text | Effect |
|-----------|------|--------|
| `incomm.ShowComments` | Show Comments | open the explorer |
| `incomm.ToggleNotes` | Hide/Show Notes | show/hide **all** inline cards (gutter icons stay) |
| `incomm.ToggleResolved` | Hide/Show Resolved | show/hide **resolved** cards only |
| `incomm.ClearFile` | Clear Comments in File | delete comments for the current file (confirm) |
| `incomm.Clear` | Clear All Comments | delete everything (confirm) |

### 6.5 Startup

- **`startup/IncommStartupActivity`** (`postStartupActivity`) — touches `NotesService`
  (loads the model), starts the tracker on the EDT, then re-anchors from disk on a pooled
  thread and publishes a refresh.

---

## 7. Key insights & gotchas (save yourself hours)

These are hard-won and non-obvious. **Respect them when changing the editor UI.**

1. **Build with JDK 21.** See §3. Symptom if you don't: Kotlin fails to parse the host JDK.
2. **Interactive inline cards use `EditorEmbeddedComponentManager`** (in
   `com.intellij.openapi.editor.impl`, but *not* `@ApiStatus.Internal` — the verifier is clean).
   Painted `EditorCustomElementRenderer` block inlays are display-only and can't host inputs.
3. **Inline text inputs must be `EditorTextField`, not `JBTextArea`.** A plain Swing text area
   inside the editor has its editing keys (Enter, Backspace, ⌥←, selection, …) hijacked by the
   editor's action system, because the outer editor is the resolved `CommonDataKeys.EDITOR`.
   `EditorTextField` is a real nested editor, so it becomes the focused `EDITOR` and all editing
   works. This was the single biggest source of "the input doesn't work" bugs.
4. **Register confirm/cancel keys with `registerCustomShortcutSet`**, not Swing input maps —
   component-local IDE shortcuts win over the editor's global actions (Cmd/Ctrl+Enter = save,
   Esc = cancel; plain Enter stays a newline in the multi-line editor).
5. **Prevent viewport jumps** when adding/removing/resizing inlays with these measures,
   all present in `NoteInlayController` / `NoteCardComponent` / `IncommEditorTracker`:
   - `EditorScrollingPositionKeeper.savePosition()` → mutate → `restorePosition(false)` **and
     again in an `invokeLater`** (embedded components get their real height only after layout);
     `refreshAll` wraps the *whole* rebuild in such keepers for every visible editor.
   - A `noScrollHost()` panel that overrides `scrollRectToVisible` to a no-op (so focusing an
     inner field doesn't scroll the page to it).
   - **Incremental reconciliation** in rebuild (don't dispose+re-add all cards; update in place).
   - **Live position updates persist *quietly***: the range markers/block inlays already track
     edits natively, so a position-only reindex writes `notes.json` **without** publishing a UI
     rebuild (which would jump). A rebuild is published only when something visual changes (a note
     un-orphans, or a dead marker had to be text-reanchored). Card line-number headers are updated
     in place via `refreshLocations()`.
   - Adding a comment swaps the composer for the resulting card **in one keep-scroll pass**
     (`startCompose` returns the new `Note`, then `addCard`), so the async refresh only refreshes
     it in place.
6. **`hiddenNotes` is the one mechanism** for "card hidden". Gutter-icon click, resolve-auto-hide,
   and the hide-resolved bulk action all manipulate it. Resolve = `setNoteResolved` = add to
   `hiddenNotes` + `setResolved(true)`; reopen removes it and shows the card.
7. **Live sync / reindex** = `RangeMarker` (edits shift notes in-editor) + a debounced
   `DocumentListener` that recomputes & persists positions on every change (not just save) +
   `AsyncFileListener`s: `NotesFileWatcher` (external `notes.json` writes reload the model) and
   `IncommSourceFileWatcher` (external source edits reanchor a file's notes from disk). Reloads
   that produce no change skip the notification (avoids self-write refresh loops). Don't add polling.
8. **Focus:** request focus for embedded inputs via `IdeFocusManager` once the component is
   showing (a `HierarchyListener` on `SHOWING_CHANGED`), not eagerly.
9. **Colours & keys convention:** every colour comes from the active theme via `IncommColors`
   (user/open blue, agent/resolved green, orphaned red) — never hard-code a colour. No default
   shortcuts.
10. **Schema parity is sacred.** Any change to the JSON shape or anchoring must land in *both*
    `Anchoring.kt`/`model` **and** `internal/anchor`/`model`, keep §11 in sync, and pass
    the shared `fixtures/`.

---

## 8. Tests

- **Plugin** (`plugin/src/test/kotlin/dev/incomm/`): `AnchoringTest` (parity vs fixtures),
  `NotesStoreTest`, `NotesServiceTest`, `EditorIntegrationTest` (gutter icons, inline cards,
  compose/reply/add/edit inlays, per-thread & resolved hide/show, caret gutter band). Run:
  `JAVA_HOME=$(/usr/libexec/java_home -v 21) ./gradlew :plugin:test`.
- **CLI** (`cli/**/*_test.go`): `anchor`, `model`, `store`, and `cmd` (`skill`, `anchor set/recompute`).
  Run: `go test ./...`.
- `verifyPlugin` must stay **Compatible** across IC 242–252 with no internal/deprecated-API
  warnings.

---

## 9. Where to change things (quick map)

| I want to… | Touch |
|------------|-------|
| Change the JSON shape or anchoring | §11 + `anchor/Anchoring.kt` + `cli/internal/anchor` + `model` on both sides + `fixtures/` |
| Add a CLI command | new file in `cli/cmd/` (register via `rootCmd.AddCommand` in `init()`), mirror `--json` |
| Add a plugin action | new class in `actions/` + register in `plugin.xml` + text in `IncommBundle.properties` |
| Change the inline card UI | `ui/NoteCardComponent.kt` (+ `ui/ThreadUi.kt` for shared bits) |
| Change the explorer | `ui/NotesExplorerPopup.kt` + `ui/NoteThreadComponent.kt` + `ui/NoteListCellRenderer.kt` |
| Change gutter icons / "+" / range band | `ui/NoteGutterIconRenderer.kt`, `ui/AddPlusGutterIconRenderer.kt`, `editor/AddGutterController.kt`, `editor/NoteRangeHighlighter.kt` |
| Change any colour | `ui/IncommColors.kt` only (theme-derived; never hard-code elsewhere) |
| Change data/persistence | `store/NotesService.kt`, `store/NotesStore.kt` |
| Change what the agent skill says | `cli/cmd/skill.go` (`skillMarkdown` const) |

---

## 10. Notes

- Add `.incomm/` to your project's `.gitignore` unless you want to commit review state.
- The plugin and CLI can both write concurrently; writes are atomic and last-write-wins,
  reconciled by the plugin's file watcher.

---

## 11. Data format & anchoring specification (the shared spec)

This chapter is the **single source of truth** shared by the IntelliJ plugin
(Kotlin) and the CLI (Go). Both implementations MUST read/write this exact
schema and implement the anchoring algorithm identically. The fixtures under
`/fixtures` are used by both test suites to guarantee parity.

### 11.1 File location

Comments live in a single JSON file at the project root:

```
<project-root>/.incomm/notes.json
```

The project root is:

- **Plugin:** the IntelliJ project's base path.
- **CLI:** the nearest ancestor directory (starting from `--root` or CWD) that
  contains a `.incomm/` directory. If none is found, `.incomm/` is created in
  `--root`/CWD.

### 11.2 JSON schema (`version: 1`)

```jsonc
{
  "version": 1,
  "notes": [
    {
      "id": "c7f3a1b2",          // stable, unique (8+ hex chars)
      "file": "src/app/main.go", // project-root-relative, POSIX separators ('/')
      "startLine": 42,            // 1-based, inclusive
      "endLine": 42,              // 1-based, inclusive; == startLine for single-line
      "anchor": {
        "startPrefix": "func doThing(ctx co", // trimmed prefix of the start line
        "endPrefix": "return nil",             // trimmed prefix of the end line
        "contextBefore": "// entrypoint",      // trimmed prefix of line above start ("" if none)
        "contextAfter": "}",                   // trimmed prefix of line below end ("" if none)
        "checksum": "sha1:9ab34f..."           // sha1 of the exact anchored block (start..end)
      },
      "content": "Please add error handling here.",
      "resolved": false,
      "orphaned": false,          // true when re-anchoring could not confidently place the note
      "author": "user",           // "user" | "agent"
      "createdAt": "2026-07-17T10:00:00Z", // RFC3339 / ISO-8601 UTC
      "updatedAt": "2026-07-17T10:00:00Z",
      "replies": [
        {
          "id": "r1a2",
          "author": "agent",       // "user" | "agent"
          "content": "Done — wrapped in an error check.",
          "createdAt": "2026-07-17T10:05:00Z"
        }
      ]
    }
  ]
}
```

#### Field rules

- Unknown fields MUST be preserved on round-trip where practical (forward-compat).
- `file` always uses `/` separators, even on Windows.
- Line numbers are **1-based** and **inclusive**. A single-line note has
  `startLine == endLine`.
- `replies` MAY be empty or omitted (treated as empty).
- Timestamps are RFC3339 in UTC (`Z`).

### 11.3 Anchoring constants

| Constant            | Value | Meaning                                             |
|---------------------|-------|-----------------------------------------------------|
| `PREFIX_LEN`        | 64    | Max chars kept for `startPrefix` / `endPrefix`      |
| `CONTEXT_PREFIX_LEN`| 48    | Max chars kept for `contextBefore` / `contextAfter` |
| `SEARCH_RADIUS`     | 400   | Max lines to search away from the last known line   |
| `MIN_PREFIX_MATCH`  | 4     | Min non-whitespace chars required to attempt a match|

A "trimmed prefix" is: take the line, strip leading/trailing ASCII whitespace,
then keep at most `N` characters (by Unicode code point).

### 11.4 Anchoring algorithm (best-effort, deterministic)

Given a note and the **current** lines of its file, recompute `startLine` /
`endLine`. Both implementations must produce identical results.

#### 1. Fast path (still valid)

If `startLine`/`endLine` are within range AND
`trimmedPrefix(lines[startLine]) == startPrefix` AND
`trimmedPrefix(lines[endLine]) == endPrefix` AND the stored context still
matches (`contextBefore` is empty or equals `trimmedPrefix(lines[startLine-1])`,
and `contextAfter` is empty or equals `trimmedPrefix(lines[endLine+1])`), the
note is unchanged. Set `orphaned = false` and return (no line change).

Checking context here matters: without it, a note whose old line coincidentally
still matches a **duplicate** prefix elsewhere would wrongly stay put instead of
following its real anchor.

#### 2. Search for the start line

If `startPrefix` has fewer than `MIN_PREFIX_MATCH` non-whitespace chars, skip to
step 4 (too weak to anchor).

Collect **candidate** line indices `i` (0-based) where
`trimmedPrefix(lines[i])` starts with `startPrefix` (or equals it), for all `i`
with `|i - (startLine-1)| <= SEARCH_RADIUS`.

Score each candidate (higher is better):

```
score  = 100                                   // base for a prefix match
score +=  60  if trimmedPrefix(lines[i]) == startPrefix      // exact prefix, not just startsWith
score +=  40  if contextBefore != "" and trimmedPrefix(lines[i-1]) == contextBefore
score +=  40  if contextAfter  != "" and trimmedPrefix(lines[i+lineSpan+1]) == contextAfter
score +=  80  if checksum matches the block [i .. i+lineSpan]  // strongest signal
score -=  distance                             // distance = |i - (startLine-1)|
```

`lineSpan = endLine - startLine` (0 for single-line). Pick the highest score;
ties break toward the **smallest distance**, then the **smallest line index**.

#### 3. Accept or reject

The best candidate is accepted if `score >= 100` (i.e. at least a real prefix
match survived). On accept:

- `newStart = i + 1` (1-based), `newEnd = newStart + lineSpan`.
- Clamp `newEnd` to the last line.
- Update `startLine`/`endLine`, refresh `anchor` from the new location, set
  `orphaned = false`.

#### 4. Give up gracefully (orphaned)

If no candidate is accepted: leave `startLine`/`endLine` unchanged and set
`orphaned = true`. How orphaned notes surface:

- **Plugin gutter/editor:** an orphaned-but-**unresolved** note floats to **line 1**
  (its real anchor is lost) with the orphaned (red) icon; an orphaned-**and-resolved**
  note is hidden from the editor entirely.
- **Plugin explorer:** orphaned rows are tinted red and labelled `orphaned` (both
  states shown side by side if also resolved). The **Include orphaned** filter (⌘O)
  is on by default; **Include resolved** (⌘R) is off by default.
- **CLI:** `list` / `show` mark the note `orphaned`.

Recovering an orphaned note: the automatic search self-heals it the moment the
anchored text reappears. If you (an agent) know exactly where the code moved,
fix it directly with the low-level anchor API (see §5):

```bash
incomm anchor set <id> --line 88          # move + recompute anchor from the file, un-orphan
incomm anchor set <id> --start-prefix "…" # or overwrite individual anchor fields
incomm anchor recompute --file src/x.go   # refresh anchor text at current lines
```

### 11.5 Live tracking & reindexing (plugin)

While a file is open in the editor, each note is backed by a `RangeMarker`, so
edits shift it automatically and the rendered blocks stay on the right line.
On top of that, a **debounced document listener reindexes positions live** —
after you add/remove lines or edit the anchored text, the plugin recomputes each
note's `startLine`/`endLine`, refreshes its `anchor`, and persists to
`notes.json` (so the CLI/agent always sees current positions). Position-only
updates persist **quietly** (no UI rebuild) because the markers already render
correctly; a rebuild happens only when something visual changes (a note
un-orphans, or a marker died and had to be text-reanchored).

If a marker is invalidated (its whole range was deleted), the plugin falls back
to the text re-anchor above and marks the note `orphaned` if that also fails.
Source files edited **outside** the IDE (e.g. by the agent via the CLI) and not
open in an editor are reanchored from disk by `IncommSourceFileWatcher`.

### 11.6 Concurrency

The file may be written by both the plugin and the CLI (agent). Writers MUST use
an **atomic write**: write to a temp file in `.incomm/` and `rename()` over
`notes.json`. The plugin watches the file and reloads on external change (a
reload that yields no change is a no-op, so the plugin's own writes don't cause
refresh loops). The model is intentionally simple: **last write wins**,
reconciled by reload.
