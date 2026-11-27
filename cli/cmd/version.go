package cmd

import (
	"runtime/debug"

	"incomm/internal/model"

	"github.com/spf13/cobra"
)

var versionCmd = &cobra.Command{
	Use:   "version",
	Short: "Print the CLI version and the notes format it understands",
	Long: `Print the CLI version and the newest notes-file format version it can read and
write. Integrations use the format version to tell whether this incomm can work
with the files they produce.`,
	Args: cobra.NoArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		if flagJSON {
			return emitJSON(map[string]any{"version": versionString(), "formatVersion": model.SchemaVersion})
		}
		out("incomm %s (notes format v%d)", versionString(), model.SchemaVersion)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}

// versionString is what incomm --version and incomm version print: the
// release alone, or for a development build the commit it was built from, so
// two dev binaries can still be told apart.
func versionString() string {
	if version != "dev" {
		return version
	}
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return version
	}
	return devVersion(info.Settings)
}

func devVersion(settings []debug.BuildSetting) string {
	var revision, modified string
	for _, s := range settings {
		switch s.Key {
		case "vcs.revision":
			revision = s.Value
		case "vcs.modified":
			modified = s.Value
		}
	}
	if revision == "" {
		return "dev"
	}
	if len(revision) > 12 {
		revision = revision[:12]
	}
	if modified == "true" {
		revision += "-dirty"
	}
	return "dev (" + revision + ")"
}
