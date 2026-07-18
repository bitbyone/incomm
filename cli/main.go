// Command incomm is the CLI companion to the incomm IntelliJ plugin.
//
// It reads and writes <project-root>/.incomm/notes.json, letting an AI agent
// list, read, add, reply to, resolve and remove line-anchored code-review
// comments. The human sees everything inline in the IDE.
package main

import "incomm/cmd"

func main() {
	cmd.Execute()
}
