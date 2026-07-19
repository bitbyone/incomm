// Package store locates the project root and reads/writes .incomm/notes[_<branch>].json.
package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"incomm/internal/git"
	"incomm/internal/model"
)

// DirName is the directory holding incomm state, at the project root.
const DirName = ".incomm"

// FileName is the default notes file inside DirName (used when no git branch
// is detected or the repo is in detached-HEAD state).
const FileName = "notes.json"

// Store is bound to a resolved project root and an optional git branch.
type Store struct {
	Root      string // absolute path of the directory that holds (or will hold) .incomm/
	RawBranch string // raw git branch name (e.g. "feature/thing"); written into JSON
	Branch    string // sanitized for filename (e.g. "feature_thing"); empty = legacy notes.json
}

// Open resolves the project root and returns a Store.
//
// If explicitRoot is non-empty it is used as the starting point; otherwise the
// current working directory is used. From there, Open walks up the directory
// tree looking for an existing .incomm/ directory and, if found, roots the
// store there. If none is found, the starting directory becomes the root and
// .incomm/ will be created on the first Save.
//
// If explicitBranch is non-empty it is used as the branch name (sanitized for
// filenames). Otherwise the branch is auto-detected by reading .git/HEAD. If
// git is unavailable or the repo is in detached-HEAD state, Branch stays empty
// and the legacy notes.json is used.
func Open(explicitRoot, explicitBranch string) (*Store, error) {
	base := explicitRoot
	if base == "" {
		wd, err := os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("determine working directory: %w", err)
		}
		base = wd
	}
	abs, err := filepath.Abs(base)
	if err != nil {
		return nil, fmt.Errorf("resolve %q: %w", base, err)
	}
	root := abs
	if found, ok := findExisting(abs); ok {
		root = found
	}
	rawBranch := explicitBranch
	if rawBranch == "" {
		rawBranch = git.DetectBranch(root)
	}
	branch := ""
	if rawBranch != "" {
		branch = git.SanitizeBranch(rawBranch)
	}
	return &Store{Root: root, RawBranch: rawBranch, Branch: branch}, nil
}

// findExisting walks up from dir looking for a directory containing .incomm/.
func findExisting(dir string) (string, bool) {
	for {
		info, err := os.Stat(filepath.Join(dir, DirName))
		if err == nil && info.IsDir() {
			return dir, true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", false
		}
		dir = parent
	}
}

// Dir returns the absolute path of the .incomm/ directory.
func (s *Store) Dir() string { return filepath.Join(s.Root, DirName) }

// NotesFileName returns the filename for the current branch. With a branch
// it is "notes_<branch>.json"; without one it is the legacy "notes.json".
func (s *Store) NotesFileName() string {
	if s.Branch == "" {
		return FileName
	}
	return "notes_" + s.Branch + ".json"
}

// NotesPath returns the absolute path of the branch-scoped notes file.
func (s *Store) NotesPath() string { return filepath.Join(s.Dir(), s.NotesFileName()) }

// Load reads the branch-scoped notes file. A missing file yields an empty,
// normalized NotesFile.
func (s *Store) Load() (*model.NotesFile, error) {
	data, err := os.ReadFile(s.NotesPath())
	if errors.Is(err, os.ErrNotExist) {
		return model.NewNotesFile(), nil
	}
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", s.NotesPath(), err)
	}
	var f model.NotesFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("parse %s: %w", s.NotesPath(), err)
	}
	f.Normalize()
	return &f, nil
}

// Save writes the branch-scoped notes file atomically (temp file + rename) with
// 2-space indent. The raw branch name is stamped into the JSON.
func (s *Store) Save(f *model.NotesFile) error {
	if s.RawBranch != "" {
		f.Branch = s.RawBranch
	}
	f.Normalize()
	data, err := json.MarshalIndent(f, "", "  ")
	if err != nil {
		return fmt.Errorf("encode notes: %w", err)
	}
	data = append(data, '\n')

	dir := s.Dir()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", dir, err)
	}
	tmp, err := os.CreateTemp(dir, ".notes-*.json.tmp")
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op if the rename succeeded
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("write temp file: %w", err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("sync temp file: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}
	if err := os.Rename(tmpName, s.NotesPath()); err != nil {
		return fmt.Errorf("replace %s: %w", s.NotesFileName(), err)
	}
	return nil
}

// Clear deletes the branch-scoped notes file. It reports whether the file
// existed. The .incomm/ directory is removed too if it becomes empty.
func (s *Store) Clear() (bool, error) {
	err := os.Remove(s.NotesPath())
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("remove %s: %w", s.NotesPath(), err)
	}
	// Best effort: drop the .incomm dir if empty.
	if entries, derr := os.ReadDir(s.Dir()); derr == nil && len(entries) == 0 {
		_ = os.Remove(s.Dir())
	}
	return true, nil
}

// RelFile converts a user-provided file path (absolute or relative to CWD) to a
// project-root-relative path using POSIX separators, as stored in the notes file.
func (s *Store) RelFile(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("resolve %q: %w", path, err)
	}
	rel, err := filepath.Rel(s.Root, abs)
	if err != nil {
		return "", fmt.Errorf("relativize %q against root %q: %w", path, s.Root, err)
	}
	if strings.HasPrefix(rel, ".."+string(filepath.Separator)) || rel == ".." {
		return "", fmt.Errorf("file %q is outside the project root %q", path, s.Root)
	}
	return filepath.ToSlash(rel), nil
}

// AbsFile resolves a project-root-relative note path back to an absolute path.
func (s *Store) AbsFile(rel string) string {
	return filepath.Join(s.Root, filepath.FromSlash(rel))
}

// ReadLines returns the lines of a project file (referenced by a note's rel
// path), with line breaks stripped. A trailing newline does not produce a
// trailing empty line.
func (s *Store) ReadLines(rel string) ([]string, error) {
	data, err := os.ReadFile(s.AbsFile(rel))
	if err != nil {
		return nil, err
	}
	return SplitLines(string(data)), nil
}

// SplitLines splits text into lines, normalizing CRLF/CR to LF semantics and
// dropping a single trailing newline so line counts match editor line numbers.
func SplitLines(text string) []string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	if text == "" {
		return []string{}
	}
	if strings.HasSuffix(text, "\n") {
		text = text[:len(text)-1]
	}
	return strings.Split(text, "\n")
}
