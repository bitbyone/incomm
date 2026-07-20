package cmd

import (
	"fmt"

	"incomm/internal/anchor"
	"incomm/internal/model"

	"github.com/spf13/cobra"
)

// anchorCmd is the parent of the low-level anchor API. These commands let an
// agent inspect and directly edit a comment's stored position and anchor text
// when the automatic re-anchoring heuristic ("reanchor") can't place it.
var anchorCmd = &cobra.Command{
	Use:   "anchor",
	Short: "Low-level inspection and editing of a comment's line anchor",
	Long: `Low-level anchor API.

Every comment stores a line position (startLine/endLine) plus a textual "anchor"
(start/end prefixes, surrounding context lines and a checksum) used to re-find
that position after the file changes. Normally compatible incomm integrations
and the "reanchor" command recompute positions automatically. When that
heuristic can't place a comment it is marked "orphaned"; an agent that knows
exactly where its own edit landed can use these commands to set the final
position or edit the anchor fields directly.`,
}

// ---- anchor get -------------------------------------------------------------

var anchorGetCmd = &cobra.Command{
	Use:   "get <id>",
	Short: "Print a comment's current position and anchor fields",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		st, err := openStore()
		if err != nil {
			return err
		}
		nf, err := st.Load()
		if err != nil {
			return err
		}
		note := nf.Find(args[0])
		if note == nil {
			return fmt.Errorf("no comment with id %q", args[0])
		}
		if flagJSON {
			return emitJSON(map[string]any{
				"id":        note.ID,
				"file":      note.File,
				"startLine": note.StartLine,
				"endLine":   note.EndLine,
				"orphaned":  note.Orphaned,
				"anchor":    note.Anchor,
			})
		}
		out("id:            %s", note.ID)
		out("file:          %s", note.File)
		out("startLine:     %d", note.StartLine)
		out("endLine:       %d", note.EndLine)
		out("orphaned:      %t", note.Orphaned)
		out("startPrefix:   %s", note.Anchor.StartPrefix)
		out("endPrefix:     %s", note.Anchor.EndPrefix)
		out("contextBefore: %s", note.Anchor.ContextBefore)
		out("contextAfter:  %s", note.Anchor.ContextAfter)
		out("checksum:      %s", note.Anchor.Checksum)
		return nil
	},
}

// ---- anchor set -------------------------------------------------------------

var (
	anchorSetLine          string
	anchorSetStartPrefix   string
	anchorSetEndPrefix     string
	anchorSetContextBefore string
	anchorSetContextAfter  string
	anchorSetChecksum      string
	anchorSetOrphaned      bool
	anchorSetNoRecompute   bool
)

var anchorSetCmd = &cobra.Command{
	Use:   "set <id>",
	Short: "Set a comment's final position and/or anchor fields",
	Long: `Set a comment's position and/or individual anchor fields.

With --line the comment is moved to those 1-based line(s); unless --no-recompute
is given, its anchor text is regenerated from the file at the new position and
the comment is un-orphaned. Any anchor field flag (--start-prefix, --end-prefix,
--context-before, --context-after, --checksum) then overrides that field. Use
--orphaned to set the flag explicitly.

Examples:
  incomm anchor set 1a2b3c4d --line 42
  incomm anchor set 1a2b3c4d --line 42:48
  incomm anchor set 1a2b3c4d --line 42 --no-recompute
  incomm anchor set 1a2b3c4d --start-prefix "func handle(" --checksum ""`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		st, err := openStore()
		if err != nil {
			return err
		}
		nf, err := st.Load()
		if err != nil {
			return err
		}
		note := nf.Find(args[0])
		if note == nil {
			return fmt.Errorf("no comment with id %q", args[0])
		}

		fieldsChanged := anyAnchorFieldChanged(cmd)
		if anchorSetLine == "" && !fieldsChanged && !cmd.Flags().Changed("orphaned") {
			return fmt.Errorf("nothing to do: pass --line and/or an anchor field flag")
		}

		// 1. Position (+ optional recompute of the anchor text from the file).
		if anchorSetLine != "" {
			start, end, perr := parseLineSpec(anchorSetLine)
			if perr != nil {
				return perr
			}
			note.StartLine = start
			note.EndLine = end
			if !anchorSetNoRecompute {
				lines, rerr := st.ReadLines(note.File)
				if rerr != nil {
					return fmt.Errorf("read %s: %w", note.File, rerr)
				}
				if start > len(lines) {
					return fmt.Errorf("line %d is past end of file (%d lines)", start, len(lines))
				}
				note.Anchor = anchor.Compute(lines, start, end)
				note.Orphaned = false
			}
		}

		// 2. Explicit raw anchor-field overrides.
		if cmd.Flags().Changed("start-prefix") {
			note.Anchor.StartPrefix = anchorSetStartPrefix
		}
		if cmd.Flags().Changed("end-prefix") {
			note.Anchor.EndPrefix = anchorSetEndPrefix
		}
		if cmd.Flags().Changed("context-before") {
			note.Anchor.ContextBefore = anchorSetContextBefore
		}
		if cmd.Flags().Changed("context-after") {
			note.Anchor.ContextAfter = anchorSetContextAfter
		}
		if cmd.Flags().Changed("checksum") {
			note.Anchor.Checksum = anchorSetChecksum
		}

		// 3. Explicit orphaned override wins over any implicit change above.
		if cmd.Flags().Changed("orphaned") {
			note.Orphaned = anchorSetOrphaned
		}

		note.UpdatedAt = model.NowUTC()
		if err := st.Save(nf); err != nil {
			return err
		}
		if flagJSON {
			return emitJSON(note)
		}
		out("Updated anchor for %s (%s:%d-%d)", note.ID, note.File, note.StartLine, note.EndLine)
		return nil
	},
}

func anyAnchorFieldChanged(cmd *cobra.Command) bool {
	for _, f := range []string{"start-prefix", "end-prefix", "context-before", "context-after", "checksum"} {
		if cmd.Flags().Changed(f) {
			return true
		}
	}
	return false
}

// ---- anchor recompute -------------------------------------------------------

var (
	anchorRecomputeID   string
	anchorRecomputeFile string
)

var anchorRecomputeCmd = &cobra.Command{
	Use:   "recompute",
	Short: "Regenerate anchor text from the file at each comment's current lines",
	Long: `Regenerate the stored anchor text (prefixes, context, checksum) from the
current file contents at each comment's existing startLine/endLine, WITHOUT
moving it. Use this after manually setting positions so future auto-reanchoring
has fresh anchor text to search for. Successfully recomputed comments are
un-orphaned. Restrict with --id or --file.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		st, err := openStore()
		if err != nil {
			return err
		}
		nf, err := st.Load()
		if err != nil {
			return err
		}

		fileFilter := ""
		if anchorRecomputeFile != "" {
			if rel, rerr := st.RelFile(anchorRecomputeFile); rerr == nil {
				fileFilter = rel
			} else {
				fileFilter = anchorRecomputeFile
			}
		}

		cache := map[string][]string{}
		missing := map[string]bool{}
		changed := 0
		for i := range nf.Notes {
			n := &nf.Notes[i]
			if anchorRecomputeID != "" && n.ID != anchorRecomputeID {
				continue
			}
			if fileFilter != "" && n.File != fileFilter {
				continue
			}
			lines, ok := cache[n.File]
			if !ok && !missing[n.File] {
				l, rerr := st.ReadLines(n.File)
				if rerr != nil {
					missing[n.File] = true
				} else {
					lines = l
					cache[n.File] = l
				}
			}
			if missing[n.File] {
				continue
			}
			newAnchor := anchor.Compute(lines, n.StartLine, n.EndLine)
			if n.Anchor != newAnchor || n.Orphaned {
				n.Anchor = newAnchor
				n.Orphaned = false
				n.UpdatedAt = model.NowUTC()
				changed++
			}
		}
		if changed > 0 {
			if err := st.Save(nf); err != nil {
				return err
			}
		}
		if flagJSON {
			return emitJSON(map[string]any{"changed": changed})
		}
		out("Recomputed %d anchor(s).", changed)
		return nil
	},
}

func init() {
	anchorSetCmd.Flags().StringVarP(&anchorSetLine, "line", "l", "", "final line or range N or N:M")
	anchorSetCmd.Flags().StringVar(&anchorSetStartPrefix, "start-prefix", "", "override anchor.startPrefix")
	anchorSetCmd.Flags().StringVar(&anchorSetEndPrefix, "end-prefix", "", "override anchor.endPrefix")
	anchorSetCmd.Flags().StringVar(&anchorSetContextBefore, "context-before", "", "override anchor.contextBefore")
	anchorSetCmd.Flags().StringVar(&anchorSetContextAfter, "context-after", "", "override anchor.contextAfter")
	anchorSetCmd.Flags().StringVar(&anchorSetChecksum, "checksum", "", "override anchor.checksum")
	anchorSetCmd.Flags().BoolVar(&anchorSetOrphaned, "orphaned", false, "set the orphaned flag explicitly")
	anchorSetCmd.Flags().BoolVar(&anchorSetNoRecompute, "no-recompute", false, "with --line, do not recompute anchor text from the file")

	anchorRecomputeCmd.Flags().StringVar(&anchorRecomputeID, "id", "", "only this comment id")
	anchorRecomputeCmd.Flags().StringVarP(&anchorRecomputeFile, "file", "f", "", "only comments for this file")

	anchorCmd.AddCommand(anchorGetCmd)
	anchorCmd.AddCommand(anchorSetCmd)
	anchorCmd.AddCommand(anchorRecomputeCmd)
	rootCmd.AddCommand(anchorCmd)
}
