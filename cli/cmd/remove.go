package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var removeCmd = &cobra.Command{
	Use:     "rm <id>",
	Aliases: []string{"remove", "delete"},
	Short:   "Delete a single comment",
	Args:    cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		id := args[0]
		st, err := openStore()
		if err != nil {
			return err
		}
		nf, err := st.Load()
		if err != nil {
			return err
		}
		note := nf.FindVisible(id, currentView())
		if note == nil {
			return noComment(id)
		}
		// Deleting the thread would take replies this view cannot see with it.
		if shown, _ := note.InView(currentView()); len(shown.Replies) != len(note.Replies) {
			return fmt.Errorf("comment %q has replies outside your view; it cannot be deleted from here", id)
		}
		nf.Remove(id)
		if err := st.Save(nf); err != nil {
			return err
		}
		if flagJSON {
			return emitJSON(map[string]any{"removed": id})
		}
		out("Removed %s", id)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(removeCmd)
}
