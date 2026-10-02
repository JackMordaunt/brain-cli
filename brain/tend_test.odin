package brain

import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"

// Tend proposes a superseded header for a note that retells newer bullets,
// a drop for a bullet whose every claim failed, and a merge for a shared
// name; approving applies each and logs it, dropping dismisses it for good,
// and the items never answer a find.
@(test)
tend_proposes_hygiene_items_and_approve_applies_them :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	// A bullet whose only claim is a path that does not exist, and a second
	// bullet with a name the fixture already has.
	learn := path.join(f.vault, "AI", "LEARNINGS.md")
	text, _ := path.read(learn)
	testing.expect_value(
		t,
		path.write(
			learn,
			strings.concatenate(
				{
					text,
					"- **gone tool** (aliases: gone, missing binary) — lives at /usr/nonexistent/gone-tool-xyz with its data under /opt/nonexistent/gone-data — fixture — 2026-01-04\n",
					"- **sqlite** (aliases: sqlite again) — a second telling of the index, newer by date — fixture — 2026-01-05\n",
				},
			),
		),
		nil,
	)
	exec(f.cli, "reindex")

	o, _, code := exec(f.cli, "tend", "--dry-run")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "propose 4 hygiene items (1 verified bullets to date)"), o)
	o, _, code = exec(f.cli, "tend")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "proposed 4 hygiene items"), o)
	o, _, _ = exec(f.cli, "inbox")
	testing.expect(t, strings.contains(o, "**tend date verified bullets**") && strings.contains(o, "1 bullets make only claims that verify"), o)
	// The index note names no handle but retells the sqlite bullet by content;
	// the old plan only names a handle, which is doctor's business, not tend's.
	testing.expect(t, strings.contains(o, "**tend supersede 2025-12-31-index-note.md**") && strings.contains(o, "**sqlite** settled later"), o)
	testing.expect(t, !strings.contains(o, "old-plan"), o)
	testing.expect(t, strings.contains(o, "**tend drop gone tool**"), o)
	testing.expect(t, strings.contains(o, "**tend merge sqlite**"), o)
	// A second sweep raises nothing new.
	o, _, _ = exec(f.cli, "tend")
	testing.expect(t, strings.contains(o, "proposed 0 hygiene items"), o)
	// The items are actions, not answers.
	o, _, _ = exec(f.cli, "find", "superseded header")
	testing.expect(t, !strings.contains(o, "tend supersede"), o)

	// Approve the date item: the sqlite bullet, whose one claim verifies, is dated today.
	o, _, code = exec(f.cli, "inbox", "approve", "1")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "applied #1 **tend date verified bullets**"), o)
	mem0, _ := path.read(path.join(f.vault, "AI", "MEMORY.md"))
	testing.expect(t, strings.contains(mem0, strings.concatenate({"`brain sync` rebuilds it — fixture — ", today_iso()})), mem0)
	// Approve the supersede: the note gains a header after its title.
	o, _, code = exec(f.cli, "inbox", "approve", "1")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "applied #1 **tend supersede"), o)
	note, _ := path.read(path.join(f.vault, "AI", "handoffs", "2025-12-31-index-note.md"))
	testing.expect(t, strings.has_prefix(note, "# index note\n\n> Superseded (brain tend, ") && strings.contains(note, "**sqlite**"), note)
	tended, _ := path.read(path.join(f.vault, "AI", "TENDED.md"))
	testing.expect(t, strings.contains(tended, "tend supersede"), tended)
	// The drop: the bullet leaves LEARNINGS for DROPPED.
	o, _, code = exec(f.cli, "inbox", "approve", "1")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, "applied #1 **tend drop gone tool**"), o)
	text, _ = path.read(learn)
	testing.expect(t, !strings.contains(text, "**gone tool**"), "dropped from the core file")
	dropped, _ := path.read(path.join(f.vault, "AI", "DROPPED.md"))
	testing.expect(t, strings.contains(dropped, "**gone tool**"), dropped)
	// Approve the merge: the telling tend could verify (and so dated today)
	// stays, the one it could not goes, newer by its own date or not.
	o, _, code = exec(f.cli, "inbox", "approve", "1")
	testing.expect_value(t, code, 0)
	text, _ = path.read(learn)
	testing.expect(t, !strings.contains(text, "sqlite again"), "the unverifiable telling went")
	mem, _ := path.read(path.join(f.vault, "AI", "MEMORY.md"))
	testing.expect(t, strings.contains(mem, "**sqlite**") && strings.contains(mem, today_iso()), "the verified telling stays, dated today")
	o, _, _ = exec(f.cli, "inbox")
	testing.expect_value(t, o, "inbox empty\n")
	// Nothing to raise once applied.
	o, _, _ = exec(f.cli, "tend")
	testing.expect(t, strings.contains(o, "proposed 0 hygiene items"), o)
}

// Settle tends once a day, silently, and approve all leaves hygiene items
// for a person.
@(test)
settle_tends_once_a_day :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.has_stdin = true
	f.cli.stdin = `{"session_id":"d1","hook_event_name":"Stop","stop_hook_active":false,"transcript_path":"/nonexistent"}`
	o, _, code := exec(f.cli, "settle")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")
	testing.expect(t, os.exists(path.join(f.state, "tend", today_iso())), "the day is stamped")
	inbox, _ := path.read(path.join(f.vault, "AI", "INBOX.md"))
	testing.expect(t, strings.contains(inbox, "tend supersede"), inbox)
	// A second stop the same day tends nothing: the inbox is as it was.
	f.cli.stdin = `{"session_id":"d2","hook_event_name":"Stop","stop_hook_active":false,"transcript_path":"/nonexistent"}`
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")
	again, _ := path.read(path.join(f.vault, "AI", "INBOX.md"))
	testing.expect_value(t, again, inbox)
	_, _, code = exec(f.cli, "propose", "- **a fact** (aliases: fact) — a plain fact for the inbox — fixture — 2026-01-06")
	testing.expect_value(t, code, 0)
	o, _, code = exec(f.cli, "inbox", "approve", "all")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**a fact**") && !strings.contains(o, "tend supersede"), o)
	inbox, _ = path.read(path.join(f.vault, "AI", "INBOX.md"))
	testing.expect(t, strings.contains(inbox, "tend supersede"), "hygiene items wait for a person")
}
