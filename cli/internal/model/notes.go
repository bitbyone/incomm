// Package model defines the on-disk data types for .incomm/notes.json.
// The JSON tags MUST match SCHEMA.md exactly; the Kotlin plugin mirrors these.
package model

import (
	"crypto/rand"
	"encoding/hex"
	"time"
)

// SchemaVersion is the current notes.json schema version.
const SchemaVersion = 1

// Author values.
const (
	AuthorUser  = "user"
	AuthorAgent = "agent"
)

// NotesFile is the root object of .incomm/notes.json.
type NotesFile struct {
	Version int    `json:"version"`
	Notes   []Note `json:"notes"`
}

// Note is a single line-anchored comment thread.
type Note struct {
	ID        string  `json:"id"`
	File      string  `json:"file"`      // project-root-relative, POSIX separators
	StartLine int     `json:"startLine"` // 1-based, inclusive
	EndLine   int     `json:"endLine"`   // 1-based, inclusive
	Anchor    Anchor  `json:"anchor"`
	Content   string  `json:"content"`
	Resolved  bool    `json:"resolved"`
	Orphaned  bool    `json:"orphaned"`
	Author    string  `json:"author"`
	CreatedAt string  `json:"createdAt"`
	UpdatedAt string  `json:"updatedAt"`
	Replies   []Reply `json:"replies"`
}

// Anchor holds the best-effort textual anchor used to re-find a note's line
// after the file changes. See SCHEMA.md for the algorithm.
type Anchor struct {
	StartPrefix   string `json:"startPrefix"`
	EndPrefix     string `json:"endPrefix"`
	ContextBefore string `json:"contextBefore"`
	ContextAfter  string `json:"contextAfter"`
	Checksum      string `json:"checksum"`
}

// Reply is a single response in a note's thread.
type Reply struct {
	ID        string `json:"id"`
	Author    string `json:"author"`
	Content   string `json:"content"`
	CreatedAt string `json:"createdAt"`
}

// NewNotesFile returns an empty, versioned notes file.
func NewNotesFile() *NotesFile {
	return &NotesFile{Version: SchemaVersion, Notes: []Note{}}
}

// Normalize makes zero-value fields safe for marshaling and use (no nil slices,
// sane version).
func (f *NotesFile) Normalize() {
	if f.Version == 0 {
		f.Version = SchemaVersion
	}
	if f.Notes == nil {
		f.Notes = []Note{}
	}
	for i := range f.Notes {
		if f.Notes[i].Replies == nil {
			f.Notes[i].Replies = []Reply{}
		}
	}
}

// Find returns a pointer to the note with the given id, or nil.
func (f *NotesFile) Find(id string) *Note {
	for i := range f.Notes {
		if f.Notes[i].ID == id {
			return &f.Notes[i]
		}
	}
	return nil
}

// Remove deletes the note with the given id. Reports whether it existed.
func (f *NotesFile) Remove(id string) bool {
	for i := range f.Notes {
		if f.Notes[i].ID == id {
			f.Notes = append(f.Notes[:i], f.Notes[i+1:]...)
			return true
		}
	}
	return false
}

// NowUTC returns the current time formatted as RFC3339 in UTC.
func NowUTC() string {
	return time.Now().UTC().Format(time.RFC3339)
}

// NewID returns a short, unique-enough hex id.
func NewID() string {
	var b [4]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand should not fail; fall back to a time-based id.
		return hex.EncodeToString([]byte(time.Now().UTC().Format("150405.000")))
	}
	return hex.EncodeToString(b[:])
}
