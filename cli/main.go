// Command incomm is an IDE-agnostic CLI for line-anchored context threads.
//
// It reads and writes branch-scoped files under <project-root>/.incomm/, letting
// AI agents, scripts and compatible editor integrations list, read, add, reply
// to, resolve and remove line-anchored comments.
package main

import "incomm/cmd"

func main() {
	cmd.Execute()
}
