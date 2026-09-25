package cmd

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"incomm/internal/anchor"
	"incomm/internal/model"
	"incomm/internal/store"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

// resetAllFlags puts every flag of every command back to its default, so the
// in-process executions of one test do not leak into the next.
func resetAllFlags(c *cobra.Command) {
	reset := func(fs *pflag.FlagSet) {
		fs.VisitAll(func(f *pflag.Flag) {
			_ = f.Value.Set(f.DefValue)
			f.Changed = false
		})
	}
	reset(c.Flags())
	reset(c.PersistentFlags())
	for _, sub := range c.Commands() {
		resetAllFlags(sub)
	}
}

// runCLI runs the CLI in-process and returns what it printed.
func runCLI(t *testing.T, args ...string) (string, error) {
	t.Helper()
	resetAllFlags(rootCmd)
	resetAnchorFlags()
	old := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = w
	rootCmd.SetArgs(args)
	runErr := rootCmd.Execute()
	w.Close()
	os.Stdout = old
	printed, _ := io.ReadAll(r)
	return string(printed), runErr
}

// viewFixture is a checkout with four threads, one per audience:
//
//	aaaa0001 agent (audience absent), with a private reply
//	bbbb0002 private
//	cccc0003 external only
//	dddd0004 agent+external, with a private reply and a published reply
func viewFixture(t *testing.T) (root string, st *store.Store) {
	t.Helper()
	root = t.TempDir()
	src := "package main\n\nfunc a() {}\n\nfunc b() {}\n\nfunc c() {}\n\nfunc d() {}\n"
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	lines := store.SplitLines(src)
	mk := func(id string, line int, audience string, replies ...model.Reply) model.Note {
		return model.Note{
			ID: id, File: "main.go", StartLine: line, EndLine: line,
			Anchor:  anchor.Compute(lines, line, line),
			Content: "thread " + id, Author: model.AuthorUser, AuthorTitle: "Jan",
			Audience: audience, CreatedAt: model.NowUTC(), UpdatedAt: model.NowUTC(),
			Replies: append([]model.Reply{}, replies...),
		}
	}
	nf := model.NewNotesFile()
	nf.Notes = []model.Note{
		mk("aaaa0001", 3, "", model.Reply{ID: "r0000001", Author: "user", Audience: model.AudiencePrivate, Content: "secret aside"}),
		mk("bbbb0002", 5, model.AudiencePrivate),
		mk("cccc0003", 7, model.AudienceExternal),
		mk("dddd0004", 9, model.AudienceBoth,
			model.Reply{ID: "r0000002", Author: "user", Audience: model.AudiencePrivate, Content: "another secret"},
			model.Reply{ID: "r0000003", Author: "agent", Audience: model.AudienceBoth, Content: "public answer"}),
	}
	st = &store.Store{Root: root}
	if err := st.Save(nf); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resetAllFlags(rootCmd); resetAnchorFlags() })
	return root, st
}

func fileBytes(t *testing.T, st *store.Store) string {
	t.Helper()
	data, err := os.ReadFile(st.NotesPath())
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestAgentViewListsOnlyWhatIsAddressedToTheAgent(t *testing.T) {
	root, _ := viewFixture(t)
	printed, err := runCLI(t, "--root", root, "--json", "list")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"aaaa0001", "dddd0004", "public answer"} {
		if !strings.Contains(printed, want) {
			t.Errorf("agent view is missing %q", want)
		}
	}
	for _, leak := range []string{"bbbb0002", "cccc0003", "secret aside", "another secret", "r0000001", "r0000002"} {
		if strings.Contains(printed, leak) {
			t.Errorf("agent view leaks %q:\n%s", leak, printed)
		}
	}
}

func TestExternalViewListsWhatBelongsOnTheForge(t *testing.T) {
	root, _ := viewFixture(t)
	printed, err := runCLI(t, "--root", root, "--view", "external", "--json", "list")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"cccc0003", "dddd0004", "public answer"} {
		if !strings.Contains(printed, want) {
			t.Errorf("external view is missing %q", want)
		}
	}
	for _, leak := range []string{"aaaa0001", "bbbb0002", "secret aside", "another secret"} {
		if strings.Contains(printed, leak) {
			t.Errorf("external view leaks %q:\n%s", leak, printed)
		}
	}
}

func TestACommentOutsideTheViewDoesNotExistByID(t *testing.T) {
	root, st := viewFixture(t)
	before := fileBytes(t, st)
	for _, args := range [][]string{
		{"show", "bbbb0002"}, {"show", "cccc0003"},
		{"reply", "bbbb0002", "-c", "hi"}, {"reply", "cccc0003", "-c", "hi"},
		{"resolve", "bbbb0002"}, {"unresolve", "cccc0003"},
		{"rm", "bbbb0002"}, {"anchor", "get", "bbbb0002"},
		{"anchor", "set", "bbbb0002", "--line", "1"},
		{"anchor", "recompute", "--id", "bbbb0002"},
		{"set", "bbbb0002", "--audience", "external"},
	} {
		_, err := runCLI(t, append([]string{"--root", root}, args...)...)
		if err == nil || !strings.Contains(err.Error(), "no comment with id") {
			t.Errorf("incomm %v: err = %v, want \"no comment with id\"", args, err)
		}
	}
	if fileBytes(t, st) != before {
		t.Error("a refused command must not change the file")
	}
	// The same external-only thread is reachable from the external view.
	if _, err := runCLI(t, "--root", root, "--view", "external", "show", "cccc0003"); err != nil {
		t.Errorf("external view: %v", err)
	}
	// Private is in no view.
	if _, err := runCLI(t, "--root", root, "--view", "external", "show", "bbbb0002"); err == nil {
		t.Error("a private comment must not be reachable from the external view")
	}
}

func TestRewritingTheFileKeepsWhatTheViewCannotSee(t *testing.T) {
	root, st := viewFixture(t)
	// list re-anchors and saves; reply and resolve save too.
	for _, args := range [][]string{
		{"list"}, {"reanchor"}, {"resolve", "aaaa0001"}, {"reply", "dddd0004", "-c", "ok"},
	} {
		if _, err := runCLI(t, append([]string{"--root", root}, args...)...); err != nil {
			t.Fatalf("incomm %v: %v", args, err)
		}
	}
	nf, err := st.Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(nf.Notes) != 4 {
		t.Fatalf("notes = %d, want all 4", len(nf.Notes))
	}
	if n := nf.Find("aaaa0001"); len(n.Replies) != 1 || n.Replies[0].Content != "secret aside" {
		t.Errorf("private reply lost: %+v", n.Replies)
	}
	if n := nf.Find("dddd0004"); len(n.Replies) != 3 {
		t.Errorf("dddd0004 replies = %d, want 3", len(n.Replies))
	}
	if nf.Find("bbbb0002") == nil || nf.Find("cccc0003") == nil {
		t.Error("a hidden thread was dropped")
	}
	if nf.Version != model.SchemaVersion {
		t.Errorf("version = %d", nf.Version)
	}
}

func TestReplyOutputHidesWhatIsOutsideTheView(t *testing.T) {
	root, _ := viewFixture(t)
	printed, err := runCLI(t, "--root", root, "--json", "reply", "dddd0004", "-c", "thanks")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(printed, "another secret") || !strings.Contains(printed, "thanks") {
		t.Errorf("reply output:\n%s", printed)
	}
}

func TestRmRefusesAThreadWithRepliesTheViewCannotSee(t *testing.T) {
	root, st := viewFixture(t)
	before := fileBytes(t, st)
	_, err := runCLI(t, "--root", root, "rm", "aaaa0001")
	if err == nil || !strings.Contains(err.Error(), "outside your view") {
		t.Fatalf("err = %v", err)
	}
	if fileBytes(t, st) != before {
		t.Error("a refused rm must not change the file")
	}
}

func TestClearOnlyRemovesWhatTheViewCanSee(t *testing.T) {
	root, st := viewFixture(t)
	// Nothing is left that the agent may delete whole: aaaa0001 and dddd0004 each
	// carry a private reply, bbbb0002 is private and cccc0003 is external only.
	printed, err := runCLI(t, "--root", root, "--json", "clear")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(printed, `"removed": 0`) {
		t.Errorf("output: %s", printed)
	}
	nf, _ := st.Load()
	if len(nf.Notes) != 4 {
		t.Fatalf("clear removed %d notes it could not see whole", 4-len(nf.Notes))
	}

	// A thread with nothing hidden under it does go.
	if _, err := runCLI(t, "--root", root, "add", "-f", filepath.Join(root, "main.go"), "-l", "1", "-c", "mine"); err != nil {
		t.Fatal(err)
	}
	if _, err := runCLI(t, "--root", root, "clear"); err != nil {
		t.Fatal(err)
	}
	nf, _ = st.Load()
	if len(nf.Notes) != 4 {
		t.Fatalf("notes after clear = %d, want the 4 hidden or partly hidden ones", len(nf.Notes))
	}
}

func TestClearRemovesTheFileWhenNothingIsLeft(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte("package main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resetAllFlags(rootCmd) })
	if _, err := runCLI(t, "--root", root, "add", "-f", filepath.Join(root, "main.go"), "-l", "1", "-c", "x"); err != nil {
		t.Fatal(err)
	}
	if _, err := runCLI(t, "--root", root, "clear"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, ".incomm")); !os.IsNotExist(err) {
		t.Errorf(".incomm should be gone: %v", err)
	}
}

func TestAddRefusesPrivateAndRecordsAudienceAndSource(t *testing.T) {
	root, st := viewFixture(t)
	_, err := runCLI(t, "--root", root, "add", "-f", filepath.Join(root, "main.go"), "-l", "1", "-c", "x", "--audience", "private")
	if err == nil || !strings.Contains(err.Error(), "editor") {
		t.Fatalf("private add: err = %v", err)
	}
	if _, err := runCLI(t, "--root", root, "add", "-f", filepath.Join(root, "main.go"), "-l", "1", "-c", "imported",
		"--audience", "agent+external", "--source-url", "https://f/x", "--source-id", "7", "--source-thread", "abc"); err != nil {
		t.Fatal(err)
	}
	nf, _ := st.Load()
	var got *model.Note
	for i := range nf.Notes {
		if nf.Notes[i].Content == "imported" {
			got = &nf.Notes[i]
		}
	}
	if got == nil || got.Audience != model.AudienceBoth ||
		got.Source == nil || got.Source.ID != 7 || got.Source.Thread != "abc" || got.Source.URL != "https://f/x" {
		t.Fatalf("stored = %+v", got)
	}
	// The default audience is written out, so the file says who sees the comment.
	if _, err := runCLI(t, "--root", root, "add", "-f", filepath.Join(root, "main.go"), "-l", "1", "-c", "plain", "--audience", "agent"); err != nil {
		t.Fatal(err)
	}
	nf, _ = st.Load()
	for _, n := range nf.Notes {
		if n.Content == "plain" && n.Audience != model.AudienceAgent {
			t.Errorf("default audience should be stored as agent, got %q", n.Audience)
		}
	}
}

func TestSetChangesAudienceAndRecordsSource(t *testing.T) {
	root, st := viewFixture(t)
	// unagit works in the external view: publish the reply, then record where it went.
	if _, err := runCLI(t, "--root", root, "--view", "external", "set", "dddd0004", "--reply", "r0000003",
		"--source-url", "https://f/n#9", "--source-id", "9"); err != nil {
		t.Fatal(err)
	}
	if _, err := runCLI(t, "--root", root, "--view", "external", "set", "cccc0003", "--audience", "agent+external",
		"--source-id", "5", "--source-thread", "th"); err != nil {
		t.Fatal(err)
	}
	nf, _ := st.Load()
	reply := nf.Find("dddd0004").Replies[1]
	if reply.ID != "r0000003" || reply.Source == nil || reply.Source.ID != 9 || reply.Source.URL != "https://f/n#9" {
		t.Errorf("reply = %+v", reply)
	}
	if n := nf.Find("cccc0003"); n.Audience != model.AudienceBoth || n.Source == nil || n.Source.Thread != "th" {
		t.Errorf("note = %+v", n)
	}
	// A private reply cannot be reached, and private cannot be set.
	if _, err := runCLI(t, "--root", root, "--view", "external", "set", "dddd0004", "--reply", "r0000002", "--source-id", "1"); err == nil {
		t.Error("a private reply must not be reachable")
	}
	if _, err := runCLI(t, "--root", root, "set", "aaaa0001", "--audience", "private"); err == nil {
		t.Error("the CLI must not make comments private")
	}
	if _, err := runCLI(t, "--root", root, "set", "aaaa0001"); err == nil {
		t.Error("set with nothing to set should say so")
	}
	if _, err := runCLI(t, "--root", root, "set", "aaaa0001", "--reply", "x", "--source-thread", "t"); err == nil {
		t.Error("a reply has no thread of its own")
	}
}

func TestAnInvalidViewIsRefused(t *testing.T) {
	root, _ := viewFixture(t)
	if _, err := runCLI(t, "--root", root, "--view", "private", "list"); err == nil {
		t.Error("--view private must be refused: private is in no view")
	}
}

func TestANewerFormatStopsEveryCommandAndLeavesTheFileAlone(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".incomm"), 0o755); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join("..", "..", "fixtures", "notes.future.json"))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, ".incomm", "notes.json")
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resetAllFlags(rootCmd) })
	for _, args := range [][]string{
		{"list"}, {"show", "f0000001"}, {"reply", "f0000001", "-c", "x"}, {"resolve", "f0000001"},
		{"rm", "f0000001"}, {"reanchor"}, {"clear"}, {"set", "f0000001", "--audience", "external"},
	} {
		_, err := runCLI(t, append([]string{"--root", root}, args...)...)
		if err == nil || !strings.Contains(err.Error(), "format v99") {
			t.Errorf("incomm %v: err = %v", args, err)
		}
	}
	after, _ := os.ReadFile(path)
	if string(after) != string(data) {
		t.Error("the newer file was modified")
	}
}

func TestVersionReportsTheFormat(t *testing.T) {
	printed, err := runCLI(t, "--json", "version")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(printed, `"formatVersion": 2`) || !strings.Contains(printed, `"version": "`) {
		t.Errorf("output: %s", printed)
	}
}
