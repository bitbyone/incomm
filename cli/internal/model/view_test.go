package model

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEffectiveAudience(t *testing.T) {
	cases := map[string]string{
		"":               AudienceAgent,
		"agent":          AudienceAgent,
		"private":        AudiencePrivate,
		"external":       AudienceExternal,
		"agent+external": AudienceBoth,
		"team":           AudiencePrivate, // a value from the future is never leaked
	}
	for in, want := range cases {
		if got := EffectiveAudience(in); got != want {
			t.Errorf("EffectiveAudience(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCLIAudienceRefusesPrivate(t *testing.T) {
	for _, ok := range []string{"agent", "external", "agent+external"} {
		if err := CLIAudience(ok); err != nil {
			t.Errorf("CLIAudience(%q) = %v", ok, err)
		}
	}
	if err := CLIAudience("private"); err == nil || !strings.Contains(err.Error(), "editor") {
		t.Errorf("private should be refused and point at the editor, got %v", err)
	}
	if err := CLIAudience("nope"); err == nil {
		t.Error("an unknown audience should be refused")
	}
}

func loadV2Fixture(t *testing.T) *NotesFile {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "fixtures", "notes.v2.sample.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f NotesFile
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatal(err)
	}
	f.Normalize()
	return &f
}

func replyIDs(n Note) []string {
	ids := []string{}
	for _, r := range n.Replies {
		ids = append(ids, r.ID)
	}
	return ids
}

func TestV2FixtureParses(t *testing.T) {
	f := loadV2Fixture(t)
	if f.Version != 2 || len(f.Notes) != 4 {
		t.Fatalf("version=%d notes=%d", f.Version, len(f.Notes))
	}
	imported := f.Find("a1000002")
	if imported.Audience != AudienceBoth {
		t.Errorf("audience = %q", imported.Audience)
	}
	want := Source{URL: "https://gitlab.example/group/app/-/merge_requests/7#note_501&x=1", ID: 501, Thread: "9f8e7d6c5b4a"}
	if imported.Source == nil || *imported.Source != want {
		t.Errorf("source = %+v", imported.Source)
	}
	if r := imported.Replies[0]; r.Source == nil || r.Source.ID != 502 || r.Source.Thread != "" {
		t.Errorf("reply source = %+v", r.Source)
	}
}

func TestInViewAgent(t *testing.T) {
	f := loadV2Fixture(t)
	view := func(id string) ([]string, bool) {
		shown, ok := f.Find(id).InView(ViewAgent)
		return replyIDs(shown), ok
	}
	// Audience absent: agent. Its external-only reply is not the agent's business.
	if ids, ok := view("a1000001"); !ok || len(ids) != 0 {
		t.Errorf("a1000001: ok=%v replies=%v", ok, ids)
	}
	// The private reply is filtered; the published one stays.
	if ids, ok := view("a1000002"); !ok || strings.Join(ids, ",") != "b1000002" {
		t.Errorf("a1000002: ok=%v replies=%v", ok, ids)
	}
	// A private root hides the whole thread, including a reply stored as agent.
	if _, ok := view("a1000003"); ok {
		t.Error("a private thread must not be visible to the agent")
	}
	if _, ok := view("a1000004"); ok {
		t.Error("an external-only thread must not be visible to the agent")
	}
}

func TestInViewExternal(t *testing.T) {
	f := loadV2Fixture(t)
	view := func(id string) ([]string, bool) {
		shown, ok := f.Find(id).InView(ViewExternal)
		return replyIDs(shown), ok
	}
	// The root is agent-only, but a reply is marked for publishing: the thread
	// is visible so the root can be published as its parent.
	if ids, ok := view("a1000001"); !ok || strings.Join(ids, ",") != "b1000001" {
		t.Errorf("a1000001: ok=%v replies=%v", ok, ids)
	}
	if ids, ok := view("a1000002"); !ok || strings.Join(ids, ",") != "b1000002" {
		t.Errorf("a1000002: ok=%v replies=%v", ok, ids)
	}
	if _, ok := view("a1000003"); ok {
		t.Error("a private thread must not be visible in any view")
	}
	if ids, ok := view("a1000004"); !ok || len(ids) != 0 {
		t.Errorf("a1000004: ok=%v replies=%v", ok, ids)
	}
}

func TestInViewDoesNotTouchTheReceiver(t *testing.T) {
	f := loadV2Fixture(t)
	n := f.Find("a1000002")
	before := len(n.Replies)
	n.InView(ViewAgent)
	if len(n.Replies) != before {
		t.Fatal("filtering a view must not remove replies from the stored note")
	}
}

func TestFindVisibleHidesWhatIsOutsideTheView(t *testing.T) {
	f := loadV2Fixture(t)
	if f.FindVisible("a1000003", ViewAgent) != nil || f.FindVisible("a1000003", ViewExternal) != nil {
		t.Error("a private comment must not be found in any view")
	}
	if f.FindVisible("a1000004", ViewAgent) != nil {
		t.Error("an external-only comment must not be found in the agent view")
	}
	if f.FindVisible("a1000004", ViewExternal) == nil {
		t.Error("an external-only comment must be found in the external view")
	}
}

func TestAudienceAndSourceAreOmittedWhenEmpty(t *testing.T) {
	data, err := json.Marshal(Note{ID: "x", Replies: []Reply{{ID: "r"}}})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "audience") || strings.Contains(string(data), "source") {
		t.Errorf("empty audience/source should not be written: %s", data)
	}
	data, _ = json.Marshal(Note{ID: "x", Audience: AudienceBoth, Source: &Source{ID: 5}})
	if !strings.Contains(string(data), `"audience":"agent+external"`) || !strings.Contains(string(data), `"source":{"id":5}`) {
		t.Errorf("audience/source missing: %s", data)
	}
}
