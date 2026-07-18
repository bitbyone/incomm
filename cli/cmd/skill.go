package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"
)

var skillCmd = &cobra.Command{
	Use:   "skill",
	Short: "Manage the incomm agent skill file",
	Long: `The skill file teaches an AI agent how to use incomm: how to read and
answer the human's line-anchored review comments, and how to leave its own
comments on specific lines while reviewing code.`,
}

var skillPathCmd = &cobra.Command{
	Use:   "path",
	Short: "Write SKILL.md to ~/.config/.incomm and print its absolute path",
	Long: `Write the incomm agent skill to ~/.config/.incomm/SKILL.md (creating the
directory if needed) and print its absolute path.

The output is the path and nothing else, so it can be piped or embedded directly
(for example into an agent's skill loader).`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		path, err := writeSkillFile()
		if err != nil {
			return err
		}
		fmt.Println(path)
		return nil
	},
}

// writeSkillFile writes the embedded SKILL.md to ~/.config/.incomm/SKILL.md and
// returns its absolute path.
func writeSkillFile() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("determine home directory: %w", err)
	}
	dir := filepath.Join(home, ".config", ".incomm")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("create %s: %w", dir, err)
	}
	path := filepath.Join(dir, "SKILL.md")
	if err := os.WriteFile(path, []byte(skillMarkdown), 0o644); err != nil {
		return "", fmt.Errorf("write %s: %w", path, err)
	}
	return path, nil
}

func init() {
	skillCmd.AddCommand(skillPathCmd)
	rootCmd.AddCommand(skillCmd)
}

// skillMarkdown is the agent-facing skill, written verbatim to SKILL.md.
// It intentionally uses ~~~ code fences (valid CommonMark) so this Go raw string
// literal can stay backtick-free.
const skillMarkdown = `---
name: incomm
description: >-
  Read and answer inline, line-anchored code-review comments a human left in the
  incomm editor plugin, and leave your own review remarks anchored to
  specific lines of files. Use when the user mentions incomm or review comments,
  asks you to address review feedback, or when you review code and want to attach
  remarks to exact lines of specific files.
---

# incomm — inline code-review comments (agent skill)

incomm is a command-line tool that reads and writes ` + "`" + `<project-root>/.incomm/notes.json` + "`" + `.
A human attaches comments to specific lines of files inside their editor. You,
the AI agent, use the incomm CLI to read those comments, do the work, and reply —
your reply shows up inline in the editor, right under the referenced line. You can also
leave your OWN comments on specific lines while reviewing code.

This is the primary way to communicate concrete answers and requests with the human
line by line, anchored to real code, instead of only in chat.

## Setup

- Run incomm from inside the project. It locates the ` + "`" + `.incomm/` + "`" + ` directory by walking
  up from the current directory. If you run it elsewhere, pass ` + "`" + `--root <project-dir>` + "`" + `.
- Add ` + "`" + `--json` + "`" + ` to any command for machine-readable output. Prefer ` + "`" + `--json` + "`" + ` and parse it.
- The ` + "`" + `--author` + "`" + ` flag defaults to ` + "`" + `agent` + "`" + ` (that is you) for ` + "`" + `add` + "`" + ` and ` + "`" + `reply` + "`" + `.
  Comments written by the human have author ` + "`" + `user` + "`" + `.

## What you can do

### A. Answer the human's comments (reply to a thread)

1. Find what the human flagged (unresolved comments):

~~~bash
incomm list --unresolved --json
~~~

2. Read one thread in full — the original comment plus every reply:

~~~bash
incomm show <id> --json
~~~

3. Do the actual work in the code.

4. Reply. Your reply appears inline in the editor at that line:

~~~bash
incomm reply <id> --content "Fixed: now streams the file instead of buffering it."
~~~

5. Mark it handled — but only once you actually addressed it:

~~~bash
incomm resolve <id>
~~~

### B. Leave your own review remarks (a new comment on specific lines)

While reviewing, attach a remark to the exact line or line range so the human sees it
in the editor at that spot:

~~~bash
# a single line
incomm add --file src/app/main.go --line 42 --content "This ignores the returned error."

# an inclusive line range 42..48  (short flags: -f file, -l line, -c content)
incomm add -f src/app/main.go -l 42:48 -c "Extract this block into a helper."
~~~

- ` + "`" + `--line N` + "`" + ` targets one line; ` + "`" + `--line N:M` + "`" + ` targets an inclusive range (1-based line numbers).
- ` + "`" + `--file` + "`" + ` is relative to the current directory or absolute; it must be inside the project root.
- The command prints the new comment id; keep it if you want to reply to or resolve it later.

## Command reference

~~~text
incomm list [--file F] [--unresolved] [--json]      list comments (optionally filtered)
incomm show <id> [--json]                            show one comment and its full thread
incomm add -f F -l N|N:M -c TEXT [--author agent]    add a comment on line(s)
incomm reply <id> -c TEXT [--author agent]           reply to a comment
incomm resolve <id>                                  mark a comment resolved
incomm unresolve <id>                                reopen a resolved comment
incomm rm <id>                                       delete one comment
incomm clear                                         delete ALL comments
incomm reanchor [--file F]                           recompute line positions after edits
incomm anchor get <id> [--json]                      show a comment's position + anchor fields
incomm anchor set <id> [--line N|N:M] [field flags]  set final position / edit anchor fields
incomm anchor recompute [--id X] [--file F]          refresh anchor text at current lines
~~~

## Fixing positions when auto-reanchor fails

After you edit files, stored line numbers self-heal: ` + "`" + `incomm reanchor` + "`" + ` (and ` + "`" + `incomm list` + "`" + `,
which reanchors first) re-find each comment by its stored anchor text. The editor
plugin does the same automatically and live as the file changes.

If the heuristic can't place a comment it is marked ` + "`" + `orphaned` + "`" + ` (its anchor text was
lost after edits). Because YOU made the edits, you often know exactly where the comment
should now live. Use the low-level ` + "`" + `anchor` + "`" + ` API to fix it directly:

~~~bash
# inspect the current stored position + anchor fields
incomm anchor get <id> --json

# you know the code the comment referred to now sits at line 88 — move it there.
# this recomputes the anchor text from the file at line 88 and clears "orphaned":
incomm anchor set <id> --line 88

# a range, and/or override individual anchor fields verbatim:
incomm anchor set <id> --line 88:94
incomm anchor set <id> --start-prefix "func handle(" --context-before "" --checksum ""

# after manually setting many positions, refresh their anchor text from the file:
incomm anchor recompute --file src/app/main.go
~~~

- ` + "`" + `anchor set --line N` + "`" + ` moves the comment and (by default) regenerates its anchor from the
  file at that line, un-orphaning it. Add ` + "`" + `--no-recompute` + "`" + ` to change only the line numbers.
- Field flags (` + "`" + `--start-prefix` + "`" + `, ` + "`" + `--end-prefix` + "`" + `, ` + "`" + `--context-before` + "`" + `, ` + "`" + `--context-after` + "`" + `,
  ` + "`" + `--checksum` + "`" + `) overwrite exactly that anchor field; ` + "`" + `--orphaned` + "`" + ` sets the flag explicitly.

## Rules and tips

- Positions self-heal: after you edit files, run ` + "`" + `incomm reanchor` + "`" + ` (or just ` + "`" + `incomm list` + "`" + `,
  which reanchors first) so stored line numbers keep pointing at the right code.
- Keep replies concrete: say what you changed and where (file:line).
- Only resolve a comment you actually addressed. If you could not, reply explaining why
  and leave it unresolved.
- ids are short hex strings, e.g. 3f9a2b17. Copy them from ` + "`" + `list` + "`" + ` / ` + "`" + `add` + "`" + ` / ` + "`" + `show` + "`" + ` output.
- If a comment is reported as orphaned, its anchor text was lost after edits. Don't re-add
  a duplicate — use ` + "`" + `incomm anchor set <id> --line N` + "`" + ` to place it where the code moved to
  (see "Fixing positions when auto-reanchor fails" above).
- Paths stored in notes are project-root-relative and use forward slashes.

## JSON output shapes (for parsing)

` + "`" + `incomm list --json` + "`" + ` returns:

~~~json
{ "notes": [ /* Note objects */ ] }
~~~

` + "`" + `incomm show` + "`" + ` / ` + "`" + `add` + "`" + ` / ` + "`" + `reply` + "`" + ` with ` + "`" + `--json` + "`" + ` return a single Note object:

~~~json
{
  "id": "3f9a2b17",
  "file": "src/app/main.go",
  "startLine": 42,
  "endLine": 42,
  "anchor": {
    "startPrefix": "func handle(ctx co",
    "endPrefix": "func handle(ctx co",
    "contextBefore": "// entrypoint",
    "contextAfter": "return nil",
    "checksum": "sha1:9ab34f…"
  },
  "content": "the comment text",
  "resolved": false,
  "orphaned": false,
  "author": "user",
  "createdAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:00:00Z",
  "replies": [
    { "id": "9c1d0e42", "author": "agent", "content": "the reply text", "createdAt": "2026-01-01T00:00:00Z" }
  ]
}
~~~

The ` + "`" + `anchor` + "`" + ` object is how a comment re-finds its line after the file changes:
` + "`" + `startPrefix` + "`" + `/` + "`" + `endPrefix` + "`" + ` are the trimmed text of the first/last anchored line,
` + "`" + `contextBefore` + "`" + `/` + "`" + `contextAfter` + "`" + ` the trimmed lines just outside the range, and
` + "`" + `checksum` + "`" + ` a hash of the exact block. ` + "`" + `incomm anchor get <id> --json` + "`" + ` returns just the
position + this object; the ` + "`" + `anchor set` + "`" + ` field flags edit these values directly.
`
