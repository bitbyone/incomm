package model

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestParseSharedSampleFixture(t *testing.T) {
	path := filepath.Join("..", "..", "..", "fixtures", "notes.sample.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var f NotesFile
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	f.Normalize()

	if f.Version != 1 {
		t.Errorf("version = %d, want 1", f.Version)
	}
	if len(f.Notes) != 3 {
		t.Fatalf("notes = %d, want 3", len(f.Notes))
	}

	n0 := f.Find("c7f3a1b2")
	if n0 == nil {
		t.Fatal("note c7f3a1b2 not found")
	}
	if n0.File != "src/app/main.go" || n0.StartLine != 12 || n0.EndLine != 12 {
		t.Errorf("n0 loc = %s:%d-%d", n0.File, n0.StartLine, n0.EndLine)
	}
	if n0.Author != AuthorUser || n0.Resolved {
		t.Errorf("n0 author=%s resolved=%v", n0.Author, n0.Resolved)
	}
	if len(n0.Replies) != 1 || n0.Replies[0].Author != AuthorAgent {
		t.Errorf("n0 replies = %+v", n0.Replies)
	}
	if n0.Anchor.StartPrefix == "" || n0.Anchor.Checksum == "" {
		t.Errorf("n0 anchor missing fields: %+v", n0.Anchor)
	}

	if n1 := f.Find("d4e5f6a7"); n1 == nil || !n1.Resolved || n1.EndLine != 34 {
		t.Errorf("n1 unexpected: %+v", n1)
	}
	if n2 := f.Find("e8f9a0b1"); n2 == nil || !n2.Orphaned || n2.Author != AuthorAgent {
		t.Errorf("n2 unexpected: %+v", n2)
	}
}

func TestRemoveAndNormalize(t *testing.T) {
	f := NewNotesFile()
	f.Notes = append(f.Notes, Note{ID: "a"}, Note{ID: "b"})
	f.Normalize()
	if f.Notes[0].Replies == nil {
		t.Error("Normalize should replace nil replies with empty slice")
	}
	if !f.Remove("a") || f.Find("a") != nil {
		t.Error("Remove('a') failed")
	}
	if f.Remove("missing") {
		t.Error("Remove of missing id should return false")
	}
	if len(f.Notes) != 1 || f.Notes[0].ID != "b" {
		t.Errorf("after remove: %+v", f.Notes)
	}
}
