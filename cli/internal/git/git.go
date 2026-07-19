// Package git provides lightweight, pure-filesystem git branch detection
// and user identity reading. It reads .git/HEAD and git config directly —
// no git binary required.
package git

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
)

// DetectBranch finds the nearest .git directory (or worktree gitdir file)
// starting from startDir and walking up, then reads the current branch name
// from HEAD. Returns an empty string if startDir is not inside a git repo,
// or if the repo is in detached-HEAD state.
func DetectBranch(startDir string) string {
	gitDir := findGitDir(startDir)
	if gitDir == "" {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(gitDir, "HEAD"))
	if err != nil {
		return ""
	}
	return parseBranch(strings.TrimSpace(string(data)))
}

// parseBranch extracts the branch name from a HEAD file's content.
// "ref: refs/heads/main"           → "main"
// "ref: refs/heads/feature/thing"  → "feature/thing"
// "abc123..."                      → "" (detached)
func parseBranch(head string) string {
	const prefix = "ref: refs/heads/"
	if strings.HasPrefix(head, prefix) {
		return head[len(prefix):]
	}
	return ""
}

// SanitizeBranch converts a git branch name into a safe filename component.
// Slashes (common in e.g. "feature/foo") become underscores.
func SanitizeBranch(branch string) string {
	return strings.ReplaceAll(branch, "/", "_")
}

// findGitDir walks up from dir looking for .git (a directory or a worktree
// gitdir file). Returns the resolved git directory path, or "" if not found.
func findGitDir(dir string) string {
	for {
		candidate := filepath.Join(dir, ".git")
		info, err := os.Stat(candidate)
		if err == nil {
			if info.IsDir() {
				return candidate
			}
			// .git is a file → worktree pointer ("gitdir: <path>")
			if gd := readGitdirFile(candidate, dir); gd != "" {
				return gd
			}
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// readGitdirFile reads a worktree .git file ("gitdir: <path>\n") and resolves
// the path relative to base if needed.
func readGitdirFile(path, base string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	line := strings.TrimSpace(string(data))
	const prefix = "gitdir: "
	if !strings.HasPrefix(line, prefix) {
		return ""
	}
	gd := line[len(prefix):]
	if !filepath.IsAbs(gd) {
		gd = filepath.Join(base, gd)
	}
	// Verify the resolved gitdir actually exists.
	if info, err := os.Stat(gd); err != nil || !info.IsDir() {
		return ""
	}
	return gd
}

// DetectUserName reads the git user.name from the local repo config
// (.git/config) and falls back to the global ~/.gitconfig. Returns "" if
// neither is set. No git binary required.
func DetectUserName(startDir string) string {
	// 1. Try local .git/config
	gitDir := findGitDir(startDir)
	if gitDir != "" {
		if name := readGitConfigUserName(filepath.Join(gitDir, "config")); name != "" {
			return name
		}
	}
	// 2. Try global ~/.gitconfig
	home, err := os.UserHomeDir()
	if err == nil {
		if name := readGitConfigUserName(filepath.Join(home, ".gitconfig")); name != "" {
			return name
		}
	}
	return ""
}

// readGitConfigUserName parses a git config file for [user] name = VALUE.
// Only handles the simple INI-like format git uses.
func readGitConfigUserName(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	inUserSection := false
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			inUserSection = strings.EqualFold(line, "[user]")
			continue
		}
		if inUserSection {
			key, value, ok := parseConfigLine(line)
			if ok && strings.EqualFold(key, "name") {
				return value
			}
		}
	}
	return ""
}

// parseConfigLine splits "key = value" or "key=value".
func parseConfigLine(line string) (string, string, bool) {
	idx := strings.IndexByte(line, '=')
	if idx < 0 {
		return "", "", false
	}
	return strings.TrimSpace(line[:idx]), strings.TrimSpace(line[idx+1:]), true
}
