package cmd

import (
	"fmt"

	"incomm/internal/model"

	"github.com/spf13/cobra"
)

func setResolved(id string, resolved bool) error {
	st, err := openStore()
	if err != nil {
		return err
	}
	nf, err := st.Load()
	if err != nil {
		return err
	}
	note := nf.Find(id)
	if note == nil {
		return fmt.Errorf("no comment with id %q", id)
	}
	note.Resolved = resolved
	note.UpdatedAt = model.NowUTC()
	if err := st.Save(nf); err != nil {
		return err
	}
	if flagJSON {
		return emitJSON(note)
	}
	if resolved {
		out("Resolved %s", id)
	} else {
		out("Reopened %s", id)
	}
	return nil
}

var resolveCmd = &cobra.Command{
	Use:   "resolve <id>",
	Short: "Mark a comment as resolved",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return setResolved(args[0], true)
	},
}

var unresolveCmd = &cobra.Command{
	Use:   "unresolve <id>",
	Short: "Mark a comment as unresolved (reopen)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return setResolved(args[0], false)
	},
}

func init() {
	rootCmd.AddCommand(resolveCmd)
	rootCmd.AddCommand(unresolveCmd)
}
