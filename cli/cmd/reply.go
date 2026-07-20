package cmd

import (
	"fmt"

	"incomm/internal/git"
	"incomm/internal/model"

	"github.com/spf13/cobra"
)

var (
	replyContent     string
	replyAuthor      string
	replyAuthorTitle string
)

var replyCmd = &cobra.Command{
	Use:   "reply <id>",
	Short: "Add a reply to a line-anchored thread",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		if replyContent == "" {
			return fmt.Errorf("--content is required")
		}
		if replyAuthor != model.AuthorUser && replyAuthor != model.AuthorAgent {
			return fmt.Errorf("--author must be %q or %q", model.AuthorUser, model.AuthorAgent)
		}
		authorTitle := replyAuthorTitle
		if replyAuthor == model.AuthorUser && authorTitle == "" {
			authorTitle = git.DetectUserName(".")
			if authorTitle == "" {
				return fmt.Errorf("--author-title is required for user-authored replies (or set git user.name)")
			}
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
			ID:          model.NewID(),
			Author:      replyAuthor,
			AuthorTitle: authorTitle,
			Content:     replyContent,
			CreatedAt:   now,
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
	replyCmd.Flags().StringVar(&replyAuthorTitle, "author-title", "", "display name (e.g. model name for agent)")
	rootCmd.AddCommand(replyCmd)
}
