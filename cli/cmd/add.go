package cmd

import (
	"fmt"
	"strconv"
	"strings"

	"incomm/internal/anchor"
	"incomm/internal/git"
	"incomm/internal/model"

	"github.com/spf13/cobra"
)

var (
	addFile        string
	addLine        string
	addContent     string
	addAuthor      string
	addAuthorTitle string
)

var addCmd = &cobra.Command{
	Use:   "add",
	Short: "Add a comment to specific line(s)",
	Long: `Add a comment anchored to a line or an inclusive line range.

Examples:
  incomm add --file src/app/main.go --line 42 --content "Handle this error."
  incomm add -f src/app/main.go -l 42:48 -c "Extract this into a helper."`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		if addFile == "" || addLine == "" || addContent == "" {
			return fmt.Errorf("--file, --line and --content are required")
		}
		startLine, endLine, err := parseLineSpec(addLine)
		if err != nil {
			return err
		}
		author := addAuthor
		if author != model.AuthorUser && author != model.AuthorAgent {
			return fmt.Errorf("--author must be %q or %q", model.AuthorUser, model.AuthorAgent)
		}
		// authorTitle is mandatory for user-authored comments.
		authorTitle := addAuthorTitle
		if author == model.AuthorUser && authorTitle == "" {
			authorTitle = git.DetectUserName(".")
			if authorTitle == "" {
				return fmt.Errorf("--author-title is required for user-authored comments (or set git user.name)")
			}
		}

		st, err := openStore()
		if err != nil {
			return err
		}
		rel, err := st.RelFile(addFile)
		if err != nil {
			return err
		}
		lines, err := st.ReadLines(rel)
		if err != nil {
			return fmt.Errorf("read target file %s: %w", addFile, err)
		}
		if startLine > len(lines) {
			return fmt.Errorf("line %d is past end of file (%d lines)", startLine, len(lines))
		}

		nf, err := st.Load()
		if err != nil {
			return err
		}
		now := model.NowUTC()
		note := model.Note{
			ID:          model.NewID(),
			File:        rel,
			StartLine:   startLine,
			EndLine:     endLine,
			Anchor:      anchor.Compute(lines, startLine, endLine),
			Content:     addContent,
			Resolved:    false,
			Orphaned:    false,
			Author:      author,
			AuthorTitle: authorTitle,
			CreatedAt:   now,
			UpdatedAt:   now,
			Replies:     []model.Reply{},
		}
		nf.Notes = append(nf.Notes, note)
		if err := st.Save(nf); err != nil {
			return err
		}

		if flagJSON {
			return emitJSON(note)
		}
		out("Added %s at %s:%d", note.ID, note.File, note.StartLine)
		return nil
	},
}

// parseLineSpec parses "N" or "N:M" (1-based, inclusive) into start,end.
func parseLineSpec(spec string) (int, int, error) {
	parts := strings.SplitN(spec, ":", 2)
	start, err := strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil || start < 1 {
		return 0, 0, fmt.Errorf("invalid line number %q", spec)
	}
	end := start
	if len(parts) == 2 {
		end, err = strconv.Atoi(strings.TrimSpace(parts[1]))
		if err != nil || end < start {
			return 0, 0, fmt.Errorf("invalid line range %q (end must be >= start)", spec)
		}
	}
	return start, end, nil
}

func init() {
	addCmd.Flags().StringVarP(&addFile, "file", "f", "", "target file (required)")
	addCmd.Flags().StringVarP(&addLine, "line", "l", "", "line or range N or N:M (required)")
	addCmd.Flags().StringVarP(&addContent, "content", "c", "", "comment text (required)")
	addCmd.Flags().StringVar(&addAuthor, "author", model.AuthorAgent, "author: user or agent")
	addCmd.Flags().StringVar(&addAuthorTitle, "author-title", "", "display name (e.g. model name for agent, git user.name for user)")
	rootCmd.AddCommand(addCmd)
}
