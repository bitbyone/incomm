package cmd

import (
	"errors"
	"os"

	"incomm/internal/anchor"
	"incomm/internal/model"
	"incomm/internal/store"

	"github.com/spf13/cobra"
)

// reanchorAll reanchors every note against its file's current contents and
// saves if anything changed. Convenience wrapper used before read operations.
func reanchorAll(st *store.Store, nf *model.NotesFile) (int, error) {
	return reanchorNotes(st, nf, "")
}

// reanchorNotes reanchors notes (optionally only those whose file == relFilter),
// persisting when something changed. Missing files mark their notes orphaned.
func reanchorNotes(st *store.Store, nf *model.NotesFile, relFilter string) (int, error) {
	cache := map[string][]string{}
	missing := map[string]bool{}
	changed := 0

	for i := range nf.Notes {
		rel := nf.Notes[i].File
		if relFilter != "" && rel != relFilter {
			continue
		}

		lines, cached := cache[rel]
		if !cached && !missing[rel] {
			l, err := st.ReadLines(rel)
			if err != nil {
				if errors.Is(err, os.ErrNotExist) {
					missing[rel] = true
				} else {
					// Transient error: skip this file this round.
					missing[rel] = true
				}
			} else {
				lines = l
				cache[rel] = l
			}
		}

		if missing[rel] {
			if !nf.Notes[i].Orphaned {
				nf.Notes[i].Orphaned = true
				changed++
			}
			continue
		}

		if anchor.Reanchor(&nf.Notes[i], lines) {
			changed++
		}
	}

	if changed > 0 {
		if err := st.Save(nf); err != nil {
			return changed, err
		}
	}
	return changed, nil
}

var reanchorFile string

var reanchorCmd = &cobra.Command{
	Use:   "reanchor",
	Short: "Recompute line positions from anchors (self-heal after edits)",
	Long: `Recompute each comment's line position by matching its stored anchor text
against the current file contents. Notes that can no longer be placed confidently
are marked orphaned.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		st, err := openStore()
		if err != nil {
			return err
		}
		nf, err := st.Load()
		if err != nil {
			return err
		}

		filter := ""
		if reanchorFile != "" {
			if rel, rerr := st.RelFile(reanchorFile); rerr == nil {
				filter = rel
			} else {
				filter = reanchorFile
			}
		}

		n, err := reanchorNotes(st, nf, filter)
		if err != nil {
			return err
		}
		if flagJSON {
			return emitJSON(map[string]any{"changed": n})
		}
		out("Reanchored %d comment(s).", n)
		return nil
	},
}

func init() {
	reanchorCmd.Flags().StringVarP(&reanchorFile, "file", "f", "", "only reanchor comments for this file")
	rootCmd.AddCommand(reanchorCmd)
}
