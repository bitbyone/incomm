package cmd

import (
	"runtime/debug"
	"testing"
)

func TestADevBuildNamesItsCommit(t *testing.T) {
	for _, c := range []struct {
		settings []debug.BuildSetting
		want     string
	}{
		{nil, "dev"},
		{[]debug.BuildSetting{{Key: "vcs.revision", Value: "4f0c5bd1a2b3c4d5e6f7"}}, "dev (4f0c5bd1a2b3)"},
		{[]debug.BuildSetting{{Key: "vcs.revision", Value: "4f0c5bd"}, {Key: "vcs.modified", Value: "true"}}, "dev (4f0c5bd-dirty)"},
	} {
		if got := devVersion(c.settings); got != c.want {
			t.Errorf("devVersion(%v) = %q, want %q", c.settings, got, c.want)
		}
	}
}
