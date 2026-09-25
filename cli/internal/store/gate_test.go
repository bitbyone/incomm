package store

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"incomm/internal/model"
)

func openWith(t *testing.T, fixture string) (*Store, string) {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, DirName), 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "fixtures", fixture))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, DirName, FileName), data, 0o644); err != nil {
		t.Fatal(err)
	}
	st, err := Open(root, "")
	if err != nil {
		t.Fatal(err)
	}
	return st, string(data)
}

func TestLoadRefusesANewerFormatEvenWhenItsShapeIsUnreadable(t *testing.T) {
	// notes.future.json has a "notes" object where this build expects an array,
	// so a plain decode would fail with a parse error: it must still be reported
	// as a version problem.
	st, before := openWith(t, "notes.future.json")
	_, err := st.Load()
	var incompatible *IncompatibleError
	if !errors.As(err, &incompatible) {
		t.Fatalf("Load error = %v, want *IncompatibleError", err)
	}
	if incompatible.Found != 99 || incompatible.Supported != model.SchemaVersion {
		t.Errorf("found=%d supported=%d", incompatible.Found, incompatible.Supported)
	}
	for _, want := range []string{".incomm/notes.json", "format v99", "understands up to v2", "update incomm"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("message %q is missing %q", err.Error(), want)
		}
	}
	after, _ := os.ReadFile(st.NotesPath())
	if string(after) != before {
		t.Error("refusing a file must leave it untouched")
	}
}

func TestAV1FileLoadsAndIsStampedWithTheCurrentVersionOnSave(t *testing.T) {
	st, _ := openWith(t, "notes.sample.json")
	f, err := st.Load()
	if err != nil {
		t.Fatal(err)
	}
	if f.Version != 1 || len(f.Notes) != 3 {
		t.Fatalf("version=%d notes=%d", f.Version, len(f.Notes))
	}
	if err := st.Save(f); err != nil {
		t.Fatal(err)
	}
	again, err := st.Load()
	if err != nil {
		t.Fatal(err)
	}
	if again.Version != model.SchemaVersion {
		t.Errorf("saved version = %d, want %d", again.Version, model.SchemaVersion)
	}
}

func TestAV2FileRoundTripsAudienceAndSource(t *testing.T) {
	st, _ := openWith(t, "notes.v2.sample.json")
	f, err := st.Load()
	if err != nil {
		t.Fatal(err)
	}
	if err := st.Save(f); err != nil {
		t.Fatal(err)
	}
	again, err := st.Load()
	if err != nil {
		t.Fatal(err)
	}
	imported := again.Find("a1000002")
	if imported.Audience != model.AudienceBoth || imported.Source == nil || imported.Source.Thread != "9f8e7d6c5b4a" {
		t.Errorf("lost fields: %+v", imported)
	}
	if again.Find("a1000003").Audience != model.AudiencePrivate || again.Find("a1000003").Replies[0].Audience != model.AudienceAgent {
		t.Error("private note or its reply changed")
	}
}
