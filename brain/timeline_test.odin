package brain

import "core:encoding/json"
import "core:strings"
import "core:testing"

import "jm:sqlite3"

// The fixture's local day for a UTC timestamp, so the test holds in any
// timezone the suite runs in.
local_day :: proc(t: ^testing.T, f: Fixture, ts: string) -> string {
	db, err := open_db(f.cli.recall_db)
	testing.expect_value(t, err, "")
	defer sqlite3.close(&db)
	return strings.clone(scalar_text(db, "select date(?,'localtime')", ts))
}

@(test)
timeline_groups_sessions_by_day_and_repo :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := recall_fixture(t)
	defer fixture_destroy(f)
	_, e, code := exec(f.cli, "week")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "no transcript sources enabled"), e)
	exec(f.cli, "recall", "--enable", "fixture")
	exec(f.cli, "recall", "--sync")

	// The fixture's sessions are years old: a week sees nothing, a wide
	// enough window sees both, each under its own directory.
	o: string
	o, _, code = exec(f.cli, "week", "--no-git")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, "nothing recorded between"), o)
	o, _, code = exec(f.cli, "week", "--since", "9999d", "--no-git")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "  omacut  /tmp/omacut\n"), o)
	testing.expect(t, strings.contains(o, "The playhead session  (2 turns, fixture)"), o)
	testing.expect(t, strings.contains(o, "      the playhead jumps to the frame you clicked"), o)
	testing.expect(t, strings.contains(o, "  other  /tmp/other\n"), o)
	testing.expect(t, strings.index(o, "omacut") < strings.index(o, "other"), "days in order")

	o, _, code = exec(f.cli, "week", "--since", "9999d", "--no-git", "--project", "other")
	testing.expect_value(t, code, 0)
	testing.expect(t, !strings.contains(o, "omacut"), o)

	day := local_day(t, f, "2026-01-01T10:00:00Z")
	o, _, code = exec(f.cli, "day", day, "--no-git")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, day), o)
	testing.expect(t, strings.contains(o, "playhead") && !strings.contains(o, "makepkg"), o)

	o, _, code = exec(f.cli, "day", day, "--no-git", "--json")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	days, _ := v.(json.Object)["days"].(json.Array)
	testing.expect_value(t, len(days), 1)
	if len(days) == 1 {
		repos, _ := days[0].(json.Object)["repos"].(json.Array)
		testing.expect_value(t, len(repos), 1)
		if len(repos) == 1 {
			testing.expect_value(t, json_string(repos[0], "repo"), "omacut")
			sessions, _ := repos[0].(json.Object)["sessions"].(json.Array)
			testing.expect_value(t, len(sessions), 1)
			if len(sessions) == 1 {
				testing.expect_value(t, json_string(sessions[0], "goal"), "the playhead jumps to the frame you clicked when scrubbing")
			}
		}
	}

	_, _, code = exec(f.cli, "day", "yesterday")
	testing.expect_value(t, code, 1)
	o, _, code = exec(f.cli, "week", "--since", "9999d", "--no-git", "--budget", "20")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "output capped"), o)
}
