package cmd

import (
	"encoding/json"
	"fmt"
	"os"

	"incomm/internal/model"
	"incomm/internal/store"
)

// openStore resolves the project root from the global --root flag and the
// branch from --branch (or auto-detected from .git/HEAD).
func openStore() (*store.Store, error) {
	return store.Open(flagRoot, flagBranch)
}

// emitJSON writes v to stdout as indented JSON.
func emitJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

// out prints a line to stdout (human output).
func out(format string, a ...any) {
	fmt.Fprintf(os.Stdout, format+"\n", a...)
}

// currentView is the validated --view. Every command that names a comment or
// prints comments goes through it, so a comment outside the view is simply not
// there: by id it is "no comment", in a listing it is absent.
func currentView() model.View {
	v, _ := model.ParseView(flagView)
	return v
}

// noComment is the answer for an id that does not exist in the current view.
func noComment(id string) error { return fmt.Errorf("no comment with id %q", id) }

// audienceOf validates an --audience value. The default audience is stored as
// the empty string, so a comment that never mentions it stays byte-for-byte what
// it was before the field existed.
func audienceOf(v string) (string, error) {
	if v == "" || v == model.AudienceAgent {
		return "", nil
	}
	if err := model.CLIAudience(v); err != nil {
		return "", err
	}
	return v, nil
}

// sourceOf builds a Source from the --source-* flags, or nil when none is set.
func sourceOf(url string, id int64, thread string) *model.Source {
	if url == "" && id == 0 && thread == "" {
		return nil
	}
	return &model.Source{URL: url, ID: id, Thread: thread}
}
