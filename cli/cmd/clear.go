package cmd

import (
	"github.com/spf13/cobra"
)

var clearCmd = &cobra.Command{
	Use:   "clear",
	Short: "Delete ALL comments for the current branch",
	Long: `Delete every comment by removing the branch-scoped notes file
(e.g. .incomm/notes_main.json, or .incomm/notes.json if git is unavailable).

This is the CLI equivalent of the "Incomm: Clear All Comments" IDE action. It is
intentionally non-interactive so agents and scripts can call it directly.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		st, err := openStore()
		if err != nil {
			return err
		}
		existed, err := st.Clear()
		if err != nil {
			return err
		}
		if flagJSON {
			return emitJSON(map[string]any{"cleared": existed})
		}
		if existed {
			out("Cleared all comments.")
		} else {
			out("Nothing to clear.")
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(clearCmd)
}
