// Package model defines the on-disk data types for .incomm/notes.json.
// The JSON tags MUST match the README data-format spec exactly; the Kotlin plugin mirrors these.
package model

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"
)

// SchemaVersion is the newest notes.json format this build understands, and the
// version every save stamps. Any change to the JSON shape bumps it, and a build
// refuses to read or write a file whose version is greater than its own.
const SchemaVersion = 2

// LegacyVersion is what a file with no version field is taken to be.
const LegacyVersion = 1

// Author values.
const (
	AuthorUser  = "user"
	AuthorAgent = "agent"
)

// Audience says who may see a comment. The empty value means AudienceAgent, which
// is what every comment was before the field existed.
const (
	AudiencePrivate  = "private"        // the author only; never returned by the CLI
	AudienceAgent    = "agent"          // the agent working in the checkout
	AudienceExternal = "external"       // meant for the forge, not shown to the agent
	AudienceBoth     = "agent+external" // the agent works on it and it belongs on the forge
)

// View is whose eyes the CLI looks through. Private comments are in no view.
type View string

const (
	ViewAgent    View = "agent"
	ViewExternal View = "external"
)

// ParseView validates a --view value.
func ParseView(s string) (View, error) {
	switch View(s) {
	case ViewAgent, ViewExternal:
		return View(s), nil
	}
	return "", fmt.Errorf("--view must be %q or %q", ViewAgent, ViewExternal)
}

// EffectiveAudience resolves an audience as stored: empty is agent, and a value
// this build does not know is private, so a newer audience is never leaked.
func EffectiveAudience(a string) string {
	switch a {
	case "", AudienceAgent:
		return AudienceAgent
	case AudiencePrivate, AudienceExternal, AudienceBoth:
		return a
	}
	return AudiencePrivate
}

// IncludesAgent reports whether the agent may see a comment of this audience.
func IncludesAgent(a string) bool {
	e := EffectiveAudience(a)
	return e == AudienceAgent || e == AudienceBoth
}

// IncludesExternal reports whether a comment of this audience belongs on the forge.
func IncludesExternal(a string) bool {
	e := EffectiveAudience(a)
	return e == AudienceExternal || e == AudienceBoth
}

// CLIAudience validates an --audience value the CLI may set. Private is
// deliberately missing: private comments are made in the editor.
func CLIAudience(a string) error {
	switch a {
	case AudienceAgent, AudienceExternal, AudienceBoth:
		return nil
	case AudiencePrivate:
		return fmt.Errorf("private comments are created in the editor, not with the CLI")
	}
	return fmt.Errorf("--audience must be %q, %q or %q", AudienceAgent, AudienceExternal, AudienceBoth)
}

// Source records where a comment came from or where it was published to. It is
// metadata for integrations: an external comment with no Source is still
// waiting to be published.
type Source struct {
	URL    string `json:"url,omitempty"`
	ID     int64  `json:"id,omitempty"`     // the comment's id on the forge
	Thread string `json:"thread,omitempty"` // the forge's discussion id; only meaningful on a thread's first comment
}

// NotesFile is the root object of .incomm/notes[_<branch>].json.
type NotesFile struct {
	Version int    `json:"version"`
	Branch  string `json:"branch,omitempty"` // raw git branch name (authoritative)
	Notes   []Note `json:"notes"`
}

// Note is a single line-anchored comment thread.
type Note struct {
	ID          string  `json:"id"`
	File        string  `json:"file"`      // project-root-relative, POSIX separators
	StartLine   int     `json:"startLine"` // 1-based, inclusive
	EndLine     int     `json:"endLine"`   // 1-based, inclusive
	Anchor      Anchor  `json:"anchor"`
	Content     string  `json:"content"`
	Resolved    bool    `json:"resolved"`
	Orphaned    bool    `json:"orphaned"`
	Author      string  `json:"author"`
	AuthorTitle string  `json:"authorTitle,omitempty"` // display name (e.g. git user.name or model name)
	Audience    string  `json:"audience,omitempty"`    // see the Audience constants; empty is agent
	Source      *Source `json:"source,omitempty"`
	CreatedAt   string  `json:"createdAt"`
	UpdatedAt   string  `json:"updatedAt"`
	Replies     []Reply `json:"replies"`
}

// Anchor holds the best-effort textual anchor used to re-find a note's line
// after the file changes. See README.md for the algorithm.
type Anchor struct {
	StartPrefix   string `json:"startPrefix"`
	EndPrefix     string `json:"endPrefix"`
	ContextBefore string `json:"contextBefore"`
	ContextAfter  string `json:"contextAfter"`
	Checksum      string `json:"checksum"`
}

// Reply is a single response in a note's thread.
type Reply struct {
	ID          string  `json:"id"`
	Author      string  `json:"author"`
	AuthorTitle string  `json:"authorTitle,omitempty"` // display name
	Audience    string  `json:"audience,omitempty"`
	Source      *Source `json:"source,omitempty"`
	Content     string  `json:"content"`
	CreatedAt   string  `json:"createdAt"`
}

// NewNotesFile returns an empty, versioned notes file.
func NewNotesFile() *NotesFile {
	return &NotesFile{Version: SchemaVersion, Notes: []Note{}}
}

// Normalize makes zero-value fields safe for marshaling and use (no nil slices,
// sane version). A file that carries no version predates versioning.
func (f *NotesFile) Normalize() {
	if f.Version == 0 {
		f.Version = LegacyVersion
	}
	if f.Notes == nil {
		f.Notes = []Note{}
	}
	// The default audience is written out rather than left implied, so a file
	// says who sees each comment. An absent value in a file that is read still
	// means the same thing; only saving fills it in.
	for i := range f.Notes {
		n := &f.Notes[i]
		if n.Replies == nil {
			n.Replies = []Reply{}
		}
		if n.Audience == "" {
			n.Audience = AudienceAgent
		}
		for j := range n.Replies {
			if n.Replies[j].Audience == "" {
				n.Replies[j].Audience = AudienceAgent
			}
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

// FindVisible is Find for a caller that looks through a view: a comment outside
// it does not exist as far as that caller can tell. The returned pointer is into
// f, so it can be changed and saved.
func (f *NotesFile) FindVisible(id string, v View) *Note {
	n := f.Find(id)
	if n == nil {
		return nil
	}
	if _, ok := n.InView(v); !ok {
		return nil
	}
	return n
}

// InView reports whether the thread is visible through v, and returns a copy
// whose replies are limited to the ones v may see. The receiver is untouched, so
// callers can filter for output and still save the whole note.
//
// A thread is as visible as its root: a private root hides everything under it,
// whatever the replies say. The agent sees a thread whose root includes the
// agent, and only the replies that include the agent. The external view sees a
// thread when the root or any reply includes external, keeps the root as the
// parent of what it shows, and only the replies that include external.
func (n Note) InView(v View) (Note, bool) {
	if EffectiveAudience(n.Audience) == AudiencePrivate {
		return Note{}, false
	}
	includes := IncludesAgent
	if v == ViewExternal {
		includes = IncludesExternal
	}
	kept := make([]Reply, 0, len(n.Replies))
	for _, r := range n.Replies {
		if includes(r.Audience) {
			kept = append(kept, r)
		}
	}
	if !includes(n.Audience) && !(v == ViewExternal && len(kept) > 0) {
		return Note{}, false
	}
	out := n
	out.Replies = kept
	return out, true
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
