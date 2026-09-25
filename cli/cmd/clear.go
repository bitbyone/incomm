package cmd

import (
	"os"

	"incomm/internal/model"

	"github.com/spf13/cobra"
)

var clearCmd = &cobra.Command{
	Use:   "clear",
	Short: "Delete all comments in your view for the current branch",
	Long: `Delete every comment you can see for the current branch. Comments outside your
view - private ones, and ones addressed to somebody else - are left alone, and so
is a thread that has replies you cannot see. When nothing is left the branch-scoped
notes file (e.g. .incomm/notes_main.json, or .incomm/notes.json if git is
unavailable) is removed.

This is intentionally non-interactive so agents and scripts can call it directly.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		st, err := openStore()
		if err != nil {
			return err
		}
		if _, err := os.Stat(st.NotesPath()); os.IsNotExist(err) {
			return reportCleared(0, false)
		}
		nf, err := st.Load()
		if err != nil {
			return err
		}
		view := currentView()
		kept := make([]model.Note, 0, len(nf.Notes))
		removed := 0
		for _, n := range nf.Notes {
			shown, visible := n.InView(view)
			if visible && len(shown.Replies) == len(n.Replies) {
				removed++
				continue
			}
			kept = append(kept, n)
		}
		if len(kept) == 0 {
			if _, err := st.Clear(); err != nil {
				return err
			}
			return reportCleared(removed, true)
		}
		if removed > 0 {
			nf.Notes = kept
			if err := st.Save(nf); err != nil {
				return err
			}
		}
		return reportCleared(removed, removed > 0)
	},
}

func reportCleared(removed int, cleared bool) error {
	if flagJSON {
		return emitJSON(map[string]any{"cleared": cleared, "removed": removed})
	}
	if cleared {
		out("Cleared %d comment(s).", removed)
	} else {
		out("Nothing to clear.")
	}
	return nil
}

func init() {
	rootCmd.AddCommand(clearCmd)
}
