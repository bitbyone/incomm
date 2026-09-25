package cmd

import (
	"fmt"

	"incomm/internal/model"

	"github.com/spf13/cobra"
)

var (
	setReply     string
	setAudience  string
	setSourceURL string
	setSourceID  int64
	setSourceThr string
)

var setCmd = &cobra.Command{
	Use:   "set <id>",
	Short: "Set a comment's audience or source",
	Long: `Change the metadata of a comment, or of one reply with --reply.

--audience says who may see it: agent, external or agent+external. Private
comments are made in the editor, not here. --source-url, --source-id and
--source-thread record where the comment came from or was published to; a value
you leave out keeps what is already stored.

Examples:
  incomm set 1a2b3c4d --audience agent+external
  incomm set 1a2b3c4d --reply 9c1d0e42 --source-url https://forge/x#note_7 --source-id 7`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		flags := cmd.Flags()
		if !flags.Changed("audience") && !flags.Changed("source-url") &&
			!flags.Changed("source-id") && !flags.Changed("source-thread") {
			return fmt.Errorf("nothing to do: pass --audience and/or a --source-* flag")
		}
		if setReply != "" && flags.Changed("source-thread") {
			return fmt.Errorf("--source-thread belongs to a whole comment, not to a reply")
		}
		audience := ""
		if flags.Changed("audience") {
			if setAudience == "" {
				return fmt.Errorf("--audience must not be empty")
			}
			var err error
			if audience, err = audienceOf(setAudience); err != nil {
				return err
			}
		}

		st, err := openStore()
		if err != nil {
			return err
		}
		nf, err := st.Load()
		if err != nil {
			return err
		}
		view := currentView()
		note := nf.FindVisible(args[0], view)
		if note == nil {
			return noComment(args[0])
		}

		target := struct {
			audience *string
			source   **model.Source
		}{&note.Audience, &note.Source}
		if setReply != "" {
			var reply *model.Reply
			for i := range note.Replies {
				if note.Replies[i].ID == setReply {
					reply = &note.Replies[i]
				}
			}
			include := model.IncludesAgent
			if view == model.ViewExternal {
				include = model.IncludesExternal
			}
			if reply == nil || !include(reply.Audience) {
				return fmt.Errorf("no reply with id %q on comment %q", setReply, args[0])
			}
			target.audience, target.source = &reply.Audience, &reply.Source
		}

		if flags.Changed("audience") {
			*target.audience = audience
		}
		if flags.Changed("source-url") || flags.Changed("source-id") || flags.Changed("source-thread") {
			src := model.Source{}
			if *target.source != nil {
				src = **target.source
			}
			if flags.Changed("source-url") {
				src.URL = setSourceURL
			}
			if flags.Changed("source-id") {
				src.ID = setSourceID
			}
			if flags.Changed("source-thread") {
				src.Thread = setSourceThr
			}
			*target.source = &src
		}
		note.UpdatedAt = model.NowUTC()
		if err := st.Save(nf); err != nil {
			return err
		}

		if flagJSON {
			// Moving a comment out of this view leaves nothing of it to show.
			shown, visible := note.InView(view)
			if !visible {
				return emitJSON(map[string]any{"id": note.ID, "audience": note.Audience})
			}
			return emitJSON(shown)
		}
		out("Updated %s", args[0])
		return nil
	},
}

func init() {
	setCmd.Flags().StringVar(&setReply, "reply", "", "change this reply instead of the comment")
	setCmd.Flags().StringVar(&setAudience, "audience", "", "who may see it: agent, external or agent+external")
	setCmd.Flags().StringVar(&setSourceURL, "source-url", "", "where the comment came from or was published to")
	setCmd.Flags().Int64Var(&setSourceID, "source-id", 0, "the comment's id on the forge")
	setCmd.Flags().StringVar(&setSourceThr, "source-thread", "", "the forge's discussion id")
	rootCmd.AddCommand(setCmd)
}
