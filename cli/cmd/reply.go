package cmd

import (
	"fmt"

	"incomm/internal/model"

	"github.com/spf13/cobra"
)

var (
	replyContent string
	replyAuthor  string
)

var replyCmd = &cobra.Command{
	Use:   "reply <id>",
	Short: "Add a reply to a comment (shows inline in the IDE)",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if replyContent == "" {
			return fmt.Errorf("--content is required")
		}
		if replyAuthor != model.AuthorUser && replyAuthor != model.AuthorAgent {
			return fmt.Errorf("--author must be %q or %q", model.AuthorUser, model.AuthorAgent)
		}
		id := args[0]

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
		now := model.NowUTC()
		reply := model.Reply{
			ID:        model.NewID(),
			Author:    replyAuthor,
			Content:   replyContent,
			CreatedAt: now,
		}
		note.Replies = append(note.Replies, reply)
		note.UpdatedAt = now
		if err := st.Save(nf); err != nil {
			return err
		}

		if flagJSON {
			return emitJSON(note)
		}
		out("Replied to %s", id)
		return nil
	},
}

func init() {
	replyCmd.Flags().StringVarP(&replyContent, "content", "c", "", "reply text (required)")
	replyCmd.Flags().StringVar(&replyAuthor, "author", model.AuthorAgent, "author: user or agent")
	rootCmd.AddCommand(replyCmd)
}
