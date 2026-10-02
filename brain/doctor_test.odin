package brain

import "core:strings"
import "core:testing"

@(test)
doctor_runs_and_promotes_by_query_frequency :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, e, code := exec(f.cli, "doctor")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, e, "")
	testing.expect(t, strings.contains(o, "== stale"), "every section prints")
	testing.expect(t, !strings.contains(o, "promote candidates ==\n┌"), "nothing promoted before any query")

	// Promotion reads the query log: three queries on the same bullet flag it.
	for _ in 0 ..< 3 {
		exec(f.cli, "find", "sqlite")
	}
	o, _, code = exec(f.cli, "doctor")
	testing.expect_value(t, code, 0)
	i := strings.index(o, "promote candidates")
	testing.expect(t, i >= 0)
	testing.expect(t, strings.contains(o[i:], "sqlite"), "doctor promotes by query frequency")
}

// A dated note whose lines name what a newer bullet names is listed, by
// file, in text and in JSON; a bullet no older note names is not.
@(test)
doctor_lists_older_notes_a_bullet_names :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	o, _, code := exec(f.cli, "doctor")
	testing.expect_value(t, code, 0)
	i := strings.index(o, "== older notes that name what a newer bullet names")
	testing.expect(t, i >= 0, o)
	testing.expect(t, strings.contains(o[i:], "AI/handoffs/2026-01-01-fixture.md (2026-01-01): 1 line(s) from :8 name **libgit2**\n"), o[i:])
	testing.expect(t, !strings.contains(o[i:], "**sqlite**"), "a bullet no older note names is not listed")
	o, _, _ = exec(f.cli, "doctor", "--json")
	testing.expect(t, strings.contains(o, `"older_notes":[{"file":"AI/handoffs/2025-12-30-old-plan.md","date":"2025-12-30","lines":2,"first_line":3,"handles":["awk empty first file"]},{"file":"AI/handoffs/2026-01-01-fixture.md","date":"2026-01-01","lines":1,"first_line":8,"handles":["libgit2"]}]`), o)
}
