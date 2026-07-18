package store

import (
	"os"
	"path/filepath"
	"testing"

	"incomm/internal/model"
)

func TestSaveLoadRoundTripAtomic(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, DirName), 0o755); err != nil {
		t.Fatal(err)
	}
	st, err := Open(root)
	if err != nil {
		t.Fatal(err)
	}

	// Missing file loads as empty.
	f, err := st.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(f.Notes) != 0 || f.Version != model.SchemaVersion {
		t.Fatalf("empty load = %+v", f)
	}

	f.Notes = append(f.Notes, model.Note{ID: "x1", File: "a.go", StartLine: 3, EndLine: 3, Author: model.AuthorUser})
	if err := st.Save(f); err != nil {
		t.Fatal(err)
	}
	// No stray temp files left behind.
	entries, _ := os.ReadDir(st.Dir())
	for _, e := range entries {
		if e.Name() != FileName {
			t.Errorf("unexpected leftover file: %s", e.Name())
		}
	}

	got, err := st.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Notes) != 1 || got.Notes[0].ID != "x1" || got.Notes[0].Replies == nil {
		t.Fatalf("round-trip mismatch: %+v", got.Notes)
	}

	existed, err := st.Clear()
	if err != nil || !existed {
		t.Fatalf("clear = %v, %v", existed, err)
	}
	if _, err := os.Stat(st.NotesPath()); !os.IsNotExist(err) {
		t.Error("notes.json should be gone after clear")
	}
}

func TestOpenWalksUpToExistingRoot(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, DirName), 0o755); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	st, err := Open(nested)
	if err != nil {
		t.Fatal(err)
	}
	// Root should resolve to the ancestor containing .incomm, not the nested dir.
	gotRoot, _ := filepath.EvalSymlinks(st.Root)
	wantRoot, _ := filepath.EvalSymlinks(root)
	if gotRoot != wantRoot {
		t.Errorf("root = %s, want %s", gotRoot, wantRoot)
	}
}

func TestRelFileRejectsOutside(t *testing.T) {
	root := t.TempDir()
	st := &Store{Root: root}
	if _, err := st.RelFile(filepath.Join(root, "src", "main.go")); err != nil {
		t.Errorf("in-root path should be accepted: %v", err)
	}
	if _, err := st.RelFile(filepath.Join(filepath.Dir(root), "outside.go")); err == nil {
		t.Error("path outside root should be rejected")
	}
}

func TestSplitLines(t *testing.T) {
	cases := map[string]int{
		"":               0,
		"one":            1,
		"one\n":          1,
		"one\ntwo":       2,
		"one\ntwo\n":     2,
		"one\r\ntwo\r\n": 2,
	}
	for in, want := range cases {
		if got := len(SplitLines(in)); got != want {
			t.Errorf("SplitLines(%q) = %d lines, want %d", in, got, want)
		}
	}
}
