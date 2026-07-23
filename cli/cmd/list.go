package cmd

import (
	"fmt"
	"sort"
	"strings"

	"incomm/internal/model"

	"github.com/spf13/cobra"
)

var (
	listFile       string
	listUnresolved bool
)

var listCmd = &cobra.Command{
	Use:   "list",
	Short: "List comments",
	Long: `List comments, optionally filtered by file or resolution state.

With --json, prints the notes array for machine consumption. Line positions are
re-anchored against the current file contents before listing.`,
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
		if _, err := reanchorAll(st, nf); err != nil {
			return err
		}

		notes := make([]model.Note, 0, len(nf.Notes))
		for _, n := range nf.Notes {
			if listFile != "" {
				rel, rerr := st.RelFile(listFile)
				if rerr != nil {
					rel = listFile
				}
				if n.File != rel && n.File != listFile {
					continue
				}
			}
			if listUnresolved && n.Resolved {
				continue
			}
			notes = append(notes, n)
		}

		sort.SliceStable(notes, func(i, j int) bool {
			if notes[i].File != notes[j].File {
				return notes[i].File < notes[j].File
			}
			return notes[i].StartLine < notes[j].StartLine
		})

		if flagJSON {
			return emitJSON(map[string]any{"notes": notes})
		}

		if len(notes) == 0 {
			out("No comments.")
			return nil
		}
		for _, n := range notes {
			out("%s", formatNoteLine(n))
		}
		return nil
	},
}

// formatNoteLine renders a compact one-liner for a note (plus reply count).
func formatNoteLine(n model.Note) string {
	state := "open"
	switch {
	case n.Orphaned:
		state = "orphaned"
	case n.Resolved:
		state = "resolved"
	}
	loc := fmt.Sprintf("%s:%d", n.File, n.StartLine)
	if n.EndLine != n.StartLine {
		loc = fmt.Sprintf("%s:%d-%d", n.File, n.StartLine, n.EndLine)
	}
	content := strings.ReplaceAll(n.Content, "\n", " ")
	if len(content) > 60 {
		content = content[:57] + "..."
	}
	replies := ""
	if len(n.Replies) > 0 {
		replies = fmt.Sprintf(" (%d repl.)", len(n.Replies))
	}
	return fmt.Sprintf("%-8s [%-8s] %-28s %s%s", n.ID, state, loc, content, replies)
}

func init() {
	listCmd.Flags().StringVarP(&listFile, "file", "f", "", "only comments for this file")
	listCmd.Flags().BoolVarP(&listUnresolved, "unresolved", "u", false, "only unresolved comments")
	rootCmd.AddCommand(listCmd)
}
