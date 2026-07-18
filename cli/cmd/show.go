package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

var showCmd = &cobra.Command{
	Use:   "show <id>",
	Short: "Show a single comment and its full thread",
	Args:  cobra.ExactArgs(1),
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
		if _, err := reanchorAll(st, nf); err != nil {
			return err
		}
		note := nf.Find(id)
		if note == nil {
			return fmt.Errorf("no comment with id %q", id)
		}

		if flagJSON {
			return emitJSON(note)
		}

		loc := fmt.Sprintf("%s:%d", note.File, note.StartLine)
		if note.EndLine != note.StartLine {
			loc = fmt.Sprintf("%s:%d-%d", note.File, note.StartLine, note.EndLine)
		}
		out("id:       %s", note.ID)
		out("location: %s", loc)
		state := "open"
		if note.Resolved {
			state = "resolved"
		}
		if note.Orphaned {
			state += " (orphaned)"
		}
		out("state:    %s", state)
		out("author:   %s", note.Author)
		out("created:  %s", note.CreatedAt)
		out("")
		out("%s", note.Content)
		if len(note.Replies) > 0 {
			out("")
			out("--- replies ---")
			for _, r := range note.Replies {
				out("[%s @ %s] %s", r.Author, r.CreatedAt, r.Content)
			}
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(showCmd)
}
