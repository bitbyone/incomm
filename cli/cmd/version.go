package cmd

import (
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
			return emitJSON(map[string]any{"version": version, "formatVersion": model.SchemaVersion})
		}
		out("incomm %s (notes format v%d)", version, model.SchemaVersion)
		return nil
	},
}

func init() {
	rootCmd.AddCommand(versionCmd)
}
