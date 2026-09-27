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
