package anchor

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"incomm/internal/model"
)

// fixturesDir locates /fixtures/anchor relative to this test file's package.
func fixturesDir(t *testing.T) string {
	t.Helper()
	// package dir is cli/internal/anchor -> repo root is three levels up.
	return filepath.Join("..", "..", "..", "fixtures", "anchor")
}

type anchorCase struct {
	Name           string       `json:"name"`
	StartLine      int          `json:"startLine"`
	EndLine        int          `json:"endLine"`
	Anchor         model.Anchor `json:"anchor"`
	ExpectStart    int          `json:"expectStartLine"`
	ExpectEnd      int          `json:"expectEndLine"`
	ExpectOrphaned bool         `json:"expectOrphaned"`
}

type anchorCases struct {
	File  string       `json:"file"`
	Cases []anchorCase `json:"cases"`
}

func splitLines(text string) []string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	if strings.HasSuffix(text, "\n") {
		text = text[:len(text)-1]
	}
	if text == "" {
		return []string{}
	}
	return strings.Split(text, "\n")
}

func TestReanchorSharedFixtures(t *testing.T) {
	dir := fixturesDir(t)

	casesRaw, err := os.ReadFile(filepath.Join(dir, "cases.json"))
	if err != nil {
		t.Fatalf("read cases.json: %v", err)
	}
	var cases anchorCases
	if err := json.Unmarshal(casesRaw, &cases); err != nil {
		t.Fatalf("parse cases.json: %v", err)
	}

	baseRaw, err := os.ReadFile(filepath.Join(dir, cases.File))
	if err != nil {
		t.Fatalf("read %s: %v", cases.File, err)
	}
	lines := splitLines(string(baseRaw))

	for _, c := range cases.Cases {
		t.Run(c.Name, func(t *testing.T) {
			n := &model.Note{
				StartLine: c.StartLine,
				EndLine:   c.EndLine,
				Anchor:    c.Anchor,
			}
			Reanchor(n, lines)
			if n.StartLine != c.ExpectStart || n.EndLine != c.ExpectEnd {
				t.Errorf("lines = %d-%d, want %d-%d", n.StartLine, n.EndLine, c.ExpectStart, c.ExpectEnd)
			}
			if n.Orphaned != c.ExpectOrphaned {
				t.Errorf("orphaned = %v, want %v", n.Orphaned, c.ExpectOrphaned)
			}
		})
	}
}

func TestComputeRoundTripsFastPath(t *testing.T) {
	lines := []string{
		"package main",
		"",
		"func main() {",
		"\tprintln(\"hi\")",
		"}",
	}
	a := Compute(lines, 3, 3)
	n := &model.Note{StartLine: 3, EndLine: 3, Anchor: a}
	if Reanchor(n, lines) {
		t.Fatalf("freshly computed anchor should hit the fast path unchanged")
	}
	if n.StartLine != 3 || n.Orphaned {
		t.Fatalf("got line %d orphaned=%v, want line 3 not orphaned", n.StartLine, n.Orphaned)
	}
}

func TestTrimmedPrefixLimitsAndTrims(t *testing.T) {
	if got := TrimmedPrefix("\t  hello world  ", 5); got != "hello" {
		t.Errorf("TrimmedPrefix = %q, want %q", got, "hello")
	}
	if got := TrimmedPrefix("   ", 10); got != "" {
		t.Errorf("TrimmedPrefix of whitespace = %q, want empty", got)
	}
}
