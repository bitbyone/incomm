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
		if !nf.Remove(id) {
			return fmt.Errorf("no comment with id %q", id)
		}
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
