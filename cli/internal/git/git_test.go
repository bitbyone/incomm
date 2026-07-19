package git

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDetectBranchRegular(t *testing.T) {
	root := t.TempDir()
	gitDir := filepath.Join(root, ".git")
	if err := os.Mkdir(gitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gitDir, "HEAD"), []byte("ref: refs/heads/main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := DetectBranch(root); got != "main" {
		t.Errorf("DetectBranch = %q, want %q", got, "main")
	}
}

func TestDetectBranchSlash(t *testing.T) {
	root := t.TempDir()
	gitDir := filepath.Join(root, ".git")
	if err := os.Mkdir(gitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gitDir, "HEAD"), []byte("ref: refs/heads/feature/cool-thing\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := DetectBranch(root); got != "feature/cool-thing" {
		t.Errorf("DetectBranch = %q, want %q", got, "feature/cool-thing")
	}
}

func TestDetectBranchDetachedHead(t *testing.T) {
	root := t.TempDir()
	gitDir := filepath.Join(root, ".git")
	if err := os.Mkdir(gitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gitDir, "HEAD"), []byte("abc123def456\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := DetectBranch(root); got != "" {
		t.Errorf("DetectBranch on detached HEAD = %q, want empty", got)
	}
}

func TestDetectBranchWalksUp(t *testing.T) {
	root := t.TempDir()
	gitDir := filepath.Join(root, ".git")
	if err := os.Mkdir(gitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(gitDir, "HEAD"), []byte("ref: refs/heads/develop\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	nested := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := DetectBranch(nested); got != "develop" {
		t.Errorf("DetectBranch from nested dir = %q, want %q", got, "develop")
	}
}

func TestDetectBranchNoGit(t *testing.T) {
	root := t.TempDir()
	if got := DetectBranch(root); got != "" {
		t.Errorf("DetectBranch without .git = %q, want empty", got)
	}
}

func TestDetectBranchWorktree(t *testing.T) {
	root := t.TempDir()

	// Simulate a worktree: .git is a file pointing to a gitdir directory.
	mainGitDir := filepath.Join(root, "main-repo", ".git")
	worktreeGitDir := filepath.Join(mainGitDir, "worktrees", "wt1")
	if err := os.MkdirAll(worktreeGitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(worktreeGitDir, "HEAD"), []byte("ref: refs/heads/wt-branch\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	worktreeRoot := filepath.Join(root, "worktree1")
	if err := os.MkdirAll(worktreeRoot, 0o755); err != nil {
		t.Fatal(err)
	}
	// .git file in the worktree points to the worktree gitdir.
	gitFileContent := "gitdir: " + worktreeGitDir + "\n"
	if err := os.WriteFile(filepath.Join(worktreeRoot, ".git"), []byte(gitFileContent), 0o644); err != nil {
		t.Fatal(err)
	}

	if got := DetectBranch(worktreeRoot); got != "wt-branch" {
		t.Errorf("DetectBranch in worktree = %q, want %q", got, "wt-branch")
	}
}

func TestSanitizeBranch(t *testing.T) {
	cases := map[string]string{
		"main":                "main",
		"feature/cool-thing":  "feature_cool-thing",
		"release/v1.2.3":     "release_v1.2.3",
		"fix/multi/level":    "fix_multi_level",
		"simple-branch":      "simple-branch",
	}
	for in, want := range cases {
		if got := SanitizeBranch(in); got != want {
			t.Errorf("SanitizeBranch(%q) = %q, want %q", in, got, want)
		}
	}
}
