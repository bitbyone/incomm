package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// version is overridable at build time with -ldflags "-X incomm/cmd.version=...".
var version = "0.1.0"

// Global flags shared by all subcommands.
var (
	flagRoot   string // explicit project root; defaults to CWD (walks up to find .incomm/)
	flagBranch string // explicit git branch; defaults to auto-detect from .git/HEAD
	flagJSON   bool   // machine-readable output for agents
)

var rootCmd = &cobra.Command{
	Use:           "incomm",
	Short:         "Line-anchored context threads for humans and AI agents",
	Version:       version,
	SilenceUsage:  true,
	SilenceErrors: true,
	Long: `incomm is an IDE-agnostic CLI for branch-scoped, line-anchored context
threads shared between humans, AI agents, scripts and compatible editor/UI
integrations.

It reads and writes <project-root>/.incomm/notes_<branch>.json (or notes.json
when git is unavailable) so an AI agent can list, read, add, reply to, resolve
and remove line-anchored comments. Compatible integrations can render the same
shared state inline next to the referenced code.

Notes are scoped to the current git branch. When you switch branches, incomm
automatically switches to the corresponding notes file.`,
}

// Execute runs the root command and exits non-zero on error.
func Execute() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "incomm: "+err.Error())
		os.Exit(1)
	}
}

func init() {
	rootCmd.PersistentFlags().StringVar(&flagRoot, "root", "",
		"project root (defaults to the current directory, walking up to find .incomm/)")
	rootCmd.PersistentFlags().StringVar(&flagBranch, "branch", "",
		"git branch name for notes scoping (defaults to auto-detect from .git/HEAD)")
	rootCmd.PersistentFlags().BoolVar(&flagJSON, "json", false,
		"emit machine-readable JSON output")
}
