package brain

import "core:encoding/json"
import "core:strings"
import "core:testing"

import "jm:path"
import "jm:sqlite3"

@(test)
claims_are_read_out_of_a_fact :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	claims := extract_claims(f.cli, "AI/MEMORY.md", 1, "h", "lives at /opt/x (see `~/notes/a.md`), run `brain doctor`; commit 7d6fbd6 at https://x.y/z/abc1234; the notes in brainfold/2026-09-28-roadmap.md; version 1.2.3; cl takes /nologo, the route /code/brain-cli/ answers 301, //two-slash-prefix marks a line, jm/YYYY-*-friction.md names them; on Windows C:\\Tools\\brain.exe and on a Mac /private/var/x")
	kinds := make([dynamic]string)
	for c in claims {
		append(&kinds, strings.concatenate({c.kind, "=", c.text}))
	}
	testing.expect_value(t, strings.join(kinds[:], " "), "path=/opt/x path=~/notes/a.md command=brain doctor sha=7d6fbd6 vault-file=brainfold/2026-09-28-roadmap.md path=C:\\Tools\\brain.exe path=/private/var/x")
	testing.expect(t, !is_sha("decade") && !is_sha("1234567") && is_sha("7d6fbd6"), "sha shape")
}

@(test)
verify_tests_claims_and_dates_what_passed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	mem := path.join(f.vault, "AI", "MEMORY.md")
	// A path under the home directory keeps the claim independent of where
	// the fixture itself lands.
	testing.expect_value(t, path.mkdirs(path.join(f.home, "notes")), nil)
	testing.expect_value(
		t,
		path.append_file(
			mem,
			strings.concatenate(
				{
					"- **vault path** (aliases: where) — the notes live at ~/notes and AI/MEMORY.md is the index; `brain doctor` reads it — fixture — 2026-01-01\n",
					"- **gone path** (aliases: missing) — the old build sat at /tmp/nonexistent-brain-test/path — fixture — 2026-01-01\n",
					"- **bad command** (aliases: typo) — run `brain reindexx` after editing — fixture — 2026-01-01\n",
				},
			),
		),
		nil,
	)
	o, _, code := exec(f.cli, "verify")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, "4 bullets make 6 checkable claims; 2 failed\n"), o)
	testing.expect(t, strings.contains(o, "**gone path** path /tmp/nonexistent-brain-test/path: not on this machine"), o)
	testing.expect(t, strings.contains(o, "**bad command** command brain reindexx: no such subcommand"), o)
	testing.expect(t, !strings.contains(o, "**vault path**") && !strings.contains(o, "**sqlite**"), o)

	o, _, code = exec(f.cli, "verify", "--json")
	testing.expect_value(t, code, 1)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	failures, _ := v.(json.Object)["failures"].(json.Array)
	testing.expect_value(t, len(failures), 2)
	if len(failures) == 2 {
		testing.expect_value(t, json_string(failures[0], "handle"), "gone path")
		testing.expect_value(t, json_string(failures[0], "text"), "/tmp/nonexistent-brain-test/path")
		testing.expect_value(t, json_string(failures[1], "text"), "brain reindexx")
		testing.expect_value(t, json_string(failures[1], "why"), "no such subcommand")
	}

	// Doctor reads the verdicts back.
	o, _, code = exec(f.cli, "doctor")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "claims that failed") && strings.contains(o, "reindexx"), o)

	// --apply dates the bullets whose claims all passed and nothing else.
	o, _, code = exec(f.cli, "verify", "--apply")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(o, "dated today: 2 bullets"), o)
	text, _ := path.read(mem)
	today := today_iso()
	testing.expect(t, strings.contains(text, strings.concatenate({"`brain doctor` reads it — fixture — ", today})), text)
	testing.expect(t, strings.contains(text, strings.concatenate({"`brain sync` rebuilds it — fixture — ", today})), text)
	testing.expect(t, strings.contains(text, "/tmp/nonexistent-brain-test/path — fixture — 2026-01-01"), text)
	testing.expect(t, strings.contains(text, "libgit2** (aliases: jm:git, git library) — the git library the app binds instead of a git binary on PATH — fixture — 2026-01-02"), "a bullet with no claim keeps its date")

	// One handle at a time.
	o, _, code = exec(f.cli, "verify", "typo")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, "1 bullets make 1 checkable claims; 1 failed\n"), o)
}

@(test)
doctor_names_bullets_served_before_a_correction_and_contradictions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := recall_fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "recall", "--enable", "fixture")
	exec(f.cli, "recall", "--sync")
	exec(f.cli, "reindex")
	// A serve in the fixture session, logged a minute before its correction.
	db, err := open_db(f.cli.db)
	testing.expect_value(t, err, "")
	sqlite3.exec(db, "insert into queries(id,ts,q,hits,caller,session) values(7,'2026-01-01 10:01:30','filmstrip',1,'claude','sess-one')")
	sqlite3.exec(db, "insert into query_hits(query_id,file,handle,rank) values(7,'AI/MEMORY.md','fixture tool',1)")
	sqlite3.close(&db)
	// Two bullets answering to one alias with nothing in common.
	testing.expect_value(
		t,
		path.append_file(
			path.join(f.vault, "AI", "LEARNINGS.md"),
			"- **index engine** (aliases: fts5) — a plain grep across every note, no database — fixture — 2026-01-03\n",
		),
		nil,
	)
	o, _, code := exec(f.cli, "doctor")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "AI/MEMORY.md **fixture tool** served 2026-01-01 10:01:30, then: No, don't move the filmstrip"), o)
	testing.expect(t, strings.contains(o, "fts5: **sqlite** (AI/MEMORY.md) and **index engine** (AI/LEARNINGS.md)") || strings.contains(o, "fts5: **index engine** (AI/LEARNINGS.md) and **sqlite** (AI/MEMORY.md)"), o)
	o, _, _ = exec(f.cli, "doctor", "--json")
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	suspect, _ := v.(json.Object)["suspect"].(json.Array)
	testing.expect_value(t, len(suspect), 1)
	if len(suspect) == 1 {
		testing.expect_value(t, json_string(suspect[0], "handle"), "fixture tool")
		testing.expect_value(t, json_string(suspect[0], "session"), "sess-one")
	}
	contra, _ := v.(json.Object)["contradictions"].(json.Array)
	testing.expect_value(t, len(contra), 1)
	if len(contra) == 1 {
		testing.expect_value(t, json_string(contra[0], "name"), "fts5")
		pair := strings.concatenate({json_string(contra[0], "a"), "+", json_string(contra[0], "b")})
		testing.expect(t, pair == "sqlite+index engine" || pair == "index engine+sqlite", pair)
	}
}
