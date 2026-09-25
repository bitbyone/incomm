package cmd

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteSkillFile(t *testing.T) {
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)

	path, err := writeSkillFile()
	if err != nil {
		t.Fatalf("writeSkillFile: %v", err)
	}

	want := filepath.Join(tmp, ".config", ".incomm", "SKILL.md")
	if path != want {
		t.Fatalf("path = %q, want %q", path, want)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	content := string(data)

	if !strings.HasPrefix(content, "---\n") {
		t.Errorf("expected YAML frontmatter at the top, got: %.40q", content)
	}
	// The skill must clearly describe both capabilities and how to reach them.
	for _, must := range []string{
		"incomm list", "incomm show", "incomm add", "incomm reply", "incomm resolve",
		"--json", "--line N:M", "reply to a thread", "new comment on specific lines",
	} {
		if !strings.Contains(content, must) {
			t.Errorf("SKILL.md is missing %q", must)
		}
	}

	// The skill keeps the agent away from what is not addressed to it, without
	// teaching it the flags that would reach it.
	for _, must := range []string{"addressed to you", "directly (always go through the CLI)", "newer format"} {
		if !strings.Contains(content, must) {
			t.Errorf("SKILL.md is missing %q", must)
		}
	}
	for _, mustNot := range []string{"--view", "private", "incomm set", "--audience"} {
		if strings.Contains(content, mustNot) {
			t.Errorf("SKILL.md must not teach %q", mustNot)
		}
	}

	// Re-writing is idempotent and overwrites cleanly.
	path2, err := writeSkillFile()
	if err != nil || path2 != want {
		t.Fatalf("second writeSkillFile: path=%q err=%v", path2, err)
	}
}
