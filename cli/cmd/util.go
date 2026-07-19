package cmd

import (
	"encoding/json"
	"fmt"
	"os"

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
