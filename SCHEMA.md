# incomm — data format & anchoring specification

This document is the **single source of truth** shared by the IntelliJ plugin
(Kotlin) and the CLI (Go). Both implementations MUST read/write this exact
schema and implement the anchoring algorithm identically. The fixtures under
`/fixtures` are used by both test suites to guarantee parity.

## File location

Comments live in a single JSON file at the project root:

```
<project-root>/.incomm/notes.json
```

The project root is:

- **Plugin:** the IntelliJ project's base path.
- **CLI:** the nearest ancestor directory (starting from `--root` or CWD) that
  contains a `.incomm/` directory. If none is found, `.incomm/` is created in
  `--root`/CWD.

## JSON schema (`version: 1`)

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

### Field rules

- Unknown fields MUST be preserved on round-trip where practical (forward-compat).
- `file` always uses `/` separators, even on Windows.
- Line numbers are **1-based** and **inclusive**. A single-line note has
  `startLine == endLine`.
- `replies` MAY be empty or omitted (treated as empty).
- Timestamps are RFC3339 in UTC (`Z`).

## Anchoring constants

| Constant            | Value | Meaning                                             |
|---------------------|-------|-----------------------------------------------------|
| `PREFIX_LEN`        | 64    | Max chars kept for `startPrefix` / `endPrefix`      |
| `CONTEXT_PREFIX_LEN`| 48    | Max chars kept for `contextBefore` / `contextAfter` |
| `SEARCH_RADIUS`     | 400   | Max lines to search away from the last known line   |
| `MIN_PREFIX_MATCH`  | 4     | Min non-whitespace chars required to attempt a match|

A "trimmed prefix" is: take the line, strip leading/trailing ASCII whitespace,
then keep at most `N` characters (by Unicode code point).

## Anchoring algorithm (best-effort, deterministic)

Given a note and the **current** lines of its file, recompute `startLine` /
`endLine`. Both implementations must produce identical results.

### 1. Fast path (still valid)

If `startLine`/`endLine` are within range AND
`trimmedPrefix(lines[startLine]) == startPrefix` AND
`trimmedPrefix(lines[endLine]) == endPrefix` AND the stored context still
matches (`contextBefore` is empty or equals `trimmedPrefix(lines[startLine-1])`,
and `contextAfter` is empty or equals `trimmedPrefix(lines[endLine+1])`), the
note is unchanged. Set `orphaned = false` and return (no line change).

Checking context here matters: without it, a note whose old line coincidentally
still matches a **duplicate** prefix elsewhere would wrongly stay put instead of
following its real anchor.

### 2. Search for the start line

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

### 3. Accept or reject

The best candidate is accepted if `score >= 100` (i.e. at least a real prefix
match survived). On accept:

- `newStart = i + 1` (1-based), `newEnd = newStart + lineSpan`.
- Clamp `newEnd` to the last line.
- Update `startLine`/`endLine`, refresh `anchor` from the new location, set
  `orphaned = false`.

### 4. Give up gracefully

If no candidate is accepted: leave `startLine`/`endLine` unchanged, set
`orphaned = true`. The plugin renders orphaned notes with a warning gutter icon
and an "unanchored" badge in the explorer; the CLI marks them in `list` output.
A human or the agent can then re-target (`incomm reanchor` after fixing, or edit)
or delete them.

## Live tracking (plugin only)

While a file is open in the editor, each note is backed by a `RangeMarker`, so
edits shift it automatically. On document **save**, the plugin reads the marker's
current line, refreshes the `anchor`, and persists. If the marker is invalidated
(its whole range was deleted), the plugin falls back to the text re-anchor above,
and marks the note `orphaned` if that also fails.

## Concurrency

The file may be written by both the plugin and the CLI (agent). Writers MUST use
an **atomic write**: write to a temp file in `.incomm/` and `rename()` over
`notes.json`. The plugin watches the file and reloads on external change. The
model is intentionally simple: **last write wins**, reconciled by reload.
