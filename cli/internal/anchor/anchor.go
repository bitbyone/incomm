// Package anchor implements the shared, deterministic line-anchoring algorithm
// specified in SCHEMA.md. The Kotlin plugin mirrors this logic exactly.
package anchor

import (
	"crypto/sha1"
	"encoding/hex"
	"strings"

	"incomm/internal/model"
)

// Tunables — MUST match SCHEMA.md and the Kotlin implementation.
const (
	PrefixLen        = 64  // max chars kept for start/end prefixes
	ContextPrefixLen = 48  // max chars kept for context-before/after
	SearchRadius     = 400 // max lines to search away from the last known line
	MinPrefixMatch   = 4   // min non-whitespace chars required to attempt a match
)

// TrimmedPrefix strips leading/trailing ASCII whitespace and keeps at most
// maxLen Unicode code points.
func TrimmedPrefix(line string, maxLen int) string {
	t := trimWS(line)
	r := []rune(t)
	if len(r) > maxLen {
		r = r[:maxLen]
	}
	return string(r)
}

// trimWS trims leading/trailing ASCII whitespace only (deterministic across
// languages, unlike Unicode-aware trimming).
func trimWS(s string) string {
	return strings.Trim(s, " \t\n\r\f\v")
}

// nonWSCount counts non-whitespace runes in s.
func nonWSCount(s string) int {
	n := 0
	for _, r := range s {
		switch r {
		case ' ', '\t', '\n', '\r', '\f', '\v':
		default:
			n++
		}
	}
	return n
}

// Checksum returns "sha1:<hex>" of the 1-based inclusive line block [start,end]
// joined by '\n'. Out-of-range requests are clamped.
func Checksum(lines []string, start, end int) string {
	if len(lines) == 0 {
		return ""
	}
	s := clamp(start, 1, len(lines))
	e := clamp(end, 1, len(lines))
	if e < s {
		e = s
	}
	block := strings.Join(lines[s-1:e], "\n")
	sum := sha1.Sum([]byte(block))
	return "sha1:" + hex.EncodeToString(sum[:])
}

// Compute builds an Anchor for a note occupying 1-based inclusive lines
// [startLine, endLine] within the given file lines.
func Compute(lines []string, startLine, endLine int) model.Anchor {
	n := len(lines)
	s := clamp(startLine, 1, max(n, 1))
	e := clamp(endLine, s, max(n, 1))

	var startPrefix, endPrefix, before, after string
	if n > 0 {
		startPrefix = TrimmedPrefix(lines[s-1], PrefixLen)
		endPrefix = TrimmedPrefix(lines[e-1], PrefixLen)
		if s-2 >= 0 {
			before = TrimmedPrefix(lines[s-2], ContextPrefixLen)
		}
		if e < n {
			after = TrimmedPrefix(lines[e], ContextPrefixLen)
		}
	}
	return model.Anchor{
		StartPrefix:   startPrefix,
		EndPrefix:     endPrefix,
		ContextBefore: before,
		ContextAfter:  after,
		Checksum:      Checksum(lines, s, e),
	}
}

// Reanchor recomputes n.StartLine/EndLine against the current file lines,
// updating n.Anchor and n.Orphaned. It reports whether the note changed.
//
// The algorithm is specified in SCHEMA.md. It preserves the note's line span
// (endLine-startLine) and does a best-effort search using the stored prefixes,
// context lines and (optionally) checksum.
func Reanchor(n *model.Note, lines []string) bool {
	before := *n
	apply(n, lines)
	return n.StartLine != before.StartLine ||
		n.EndLine != before.EndLine ||
		n.Orphaned != before.Orphaned ||
		n.Anchor != before.Anchor
}

func apply(n *model.Note, lines []string) {
	total := len(lines)
	lineSpan := n.EndLine - n.StartLine
	if lineSpan < 0 {
		lineSpan = 0
	}

	// 1. Fast path — still where we left it (prefixes AND any stored context match).
	if n.StartLine >= 1 && n.EndLine >= 1 && n.EndLine <= total &&
		TrimmedPrefix(lines[n.StartLine-1], PrefixLen) == n.Anchor.StartPrefix &&
		TrimmedPrefix(lines[n.EndLine-1], PrefixLen) == n.Anchor.EndPrefix &&
		contextMatches(lines, n.StartLine-1, n.EndLine-1, n.Anchor) {
		n.Orphaned = false
		return
	}

	// 2. Too weak to anchor -> give up.
	if nonWSCount(n.Anchor.StartPrefix) < MinPrefixMatch {
		n.Orphaned = true
		return
	}

	// 3. Search + score candidates.
	oldIdx := n.StartLine - 1
	bestIdx := -1
	bestScore := 0
	bestDist := 0
	for i := 0; i < total; i++ {
		dist := abs(i - oldIdx)
		if dist > SearchRadius {
			continue
		}
		cand := TrimmedPrefix(lines[i], PrefixLen)
		if !strings.HasPrefix(cand, n.Anchor.StartPrefix) {
			continue
		}
		score := 100
		if cand == n.Anchor.StartPrefix {
			score += 60
		}
		if n.Anchor.ContextBefore != "" && i-1 >= 0 &&
			TrimmedPrefix(lines[i-1], ContextPrefixLen) == n.Anchor.ContextBefore {
			score += 40
		}
		if n.Anchor.ContextAfter != "" && i+lineSpan+1 < total &&
			TrimmedPrefix(lines[i+lineSpan+1], ContextPrefixLen) == n.Anchor.ContextAfter {
			score += 40
		}
		if n.Anchor.Checksum != "" &&
			Checksum(lines, i+1, i+1+lineSpan) == n.Anchor.Checksum {
			score += 80
		}
		score -= dist

		// Higher score wins; tie -> smaller distance -> smaller index.
		if bestIdx == -1 || score > bestScore ||
			(score == bestScore && dist < bestDist) {
			bestIdx, bestScore, bestDist = i, score, dist
		}
	}

	// 4. Accept or give up.
	if bestIdx == -1 || bestScore < 100 {
		n.Orphaned = true
		return
	}
	newStart := bestIdx + 1
	newEnd := clamp(newStart+lineSpan, newStart, total)
	n.StartLine = newStart
	n.EndLine = newEnd
	n.Anchor = Compute(lines, newStart, newEnd)
	n.Orphaned = false
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// contextMatches reports whether the stored context lines (if any) still match
// around the 0-based [startIdx, endIdx] block. Empty context always matches.
func contextMatches(lines []string, startIdx, endIdx int, a model.Anchor) bool {
	if a.ContextBefore != "" {
		if startIdx-1 < 0 || TrimmedPrefix(lines[startIdx-1], ContextPrefixLen) != a.ContextBefore {
			return false
		}
	}
	if a.ContextAfter != "" {
		if endIdx+1 >= len(lines) || TrimmedPrefix(lines[endIdx+1], ContextPrefixLen) != a.ContextAfter {
			return false
		}
	}
	return true
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
