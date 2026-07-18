package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"incomm/internal/anchor"
	"incomm/internal/model"
	"incomm/internal/store"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// resetAnchorFlags clears leftover flag values and cobra's per-flag "Changed"
// state so sequential in-process command executions don't leak into each other.
func resetAnchorFlags() {
	for _, c := range []*cobra.Command{anchorSetCmd, anchorRecomputeCmd} {
		c.Flags().VisitAll(func(f *pflag.Flag) { f.Changed = false })
	}
	anchorSetLine, anchorSetStartPrefix, anchorSetEndPrefix = "", "", ""
	anchorSetContextBefore, anchorSetContextAfter, anchorSetChecksum = "", "", ""
	anchorSetOrphaned, anchorSetNoRecompute = false, false
	anchorRecomputeID, anchorRecomputeFile = "", ""
}

func runIncomm(t *testing.T, args ...string) {
	t.Helper()
	resetAnchorFlags()
	rootCmd.SetArgs(args)
	if err := rootCmd.Execute(); err != nil {
		t.Fatalf("incomm %v: %v", args, err)
	}
}

func TestAnchorSetAndRecompute(t *testing.T) {
	tmp := t.TempDir()
	src := "package main\n\nfunc main() {}\n\nfunc helper() {}\n"
	if err := os.WriteFile(filepath.Join(tmp, "main.go"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}

	st := &store.Store{Root: tmp}
	lines := store.SplitLines(src)
	nf := model.NewNotesFile()
	nf.Notes = append(nf.Notes, model.Note{
		ID:        "abcd1234",
		File:      "main.go",
		StartLine: 3,
		EndLine:   3,
		Anchor:    anchor.Compute(lines, 3, 3),
		Content:   "x",
		Orphaned:  true, // should be cleared by `anchor set --line`
		Author:    model.AuthorAgent,
		CreatedAt: model.NowUTC(),
		UpdatedAt: model.NowUTC(),
		Replies:   []model.Reply{},
	})
	if err := st.Save(nf); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { flagRoot = ""; flagJSON = false })

	// Move to line 5: recomputes the anchor from the file and un-orphans.
	runIncomm(t, "--root", tmp, "anchor", "set", "abcd1234", "--line", "5")
	got := mustFind(t, st, "abcd1234")
	if got.StartLine != 5 || got.EndLine != 5 {
		t.Fatalf("lines = %d-%d, want 5-5", got.StartLine, got.EndLine)
	}
	if got.Orphaned {
		t.Fatalf("expected orphaned to be cleared")
	}
	want := anchor.Compute(lines, 5, 5)
	if got.Anchor != want {
		t.Fatalf("anchor not recomputed at new line:\n got  %+v\n want %+v", got.Anchor, want)
	}

	// Raw field override replaces exactly that field.
	runIncomm(t, "--root", tmp, "anchor", "set", "abcd1234", "--start-prefix", "OVERRIDE")
	if got := mustFind(t, st, "abcd1234"); got.Anchor.StartPrefix != "OVERRIDE" {
		t.Fatalf("start-prefix = %q, want OVERRIDE", got.Anchor.StartPrefix)
	}

	// Recompute restores the anchor text from the file at the current line.
	runIncomm(t, "--root", tmp, "anchor", "recompute", "--id", "abcd1234")
	if got := mustFind(t, st, "abcd1234"); got.Anchor != want {
		t.Fatalf("recompute did not restore anchor:\n got  %+v\n want %+v", got.Anchor, want)
	}

	// --no-recompute only changes the line numbers, leaving the anchor intact.
	runIncomm(t, "--root", tmp, "anchor", "set", "abcd1234", "--line", "1", "--no-recompute")
	if got := mustFind(t, st, "abcd1234"); got.StartLine != 1 || got.Anchor != want {
		t.Fatalf("no-recompute changed anchor or wrong line: line=%d anchor=%+v", got.StartLine, got.Anchor)
	}
}

func mustFind(t *testing.T, st *store.Store, id string) *model.Note {
	t.Helper()
	nf, err := st.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	n := nf.Find(id)
	if n == nil {
		t.Fatalf("note %q not found", id)
	}
	return n
}
