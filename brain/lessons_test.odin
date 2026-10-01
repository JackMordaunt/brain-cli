package brain

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
corrections_are_recognised_by_their_opening :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect(t, is_correction("No, don't move the filmstrip"), "no")
	testing.expect(t, is_correction("That's not what I meant."), "that's not")
	testing.expect(t, is_correction("revert that last change"), "revert")
	testing.expect(t, is_correction("ok but I said use the debug build"), "phrase")
	testing.expect(t, !is_correction("Now add the tests"), "now is not no")
	testing.expect(t, !is_correction("no problem, carry on"), "no problem")
	testing.expect(t, !is_correction("<system-reminder>x</system-reminder>"), "markup")
	testing.expect(t, same_command("just build", "just build SAN="), "retouched")
	testing.expect(t, !same_command("just build", "git status"), "another program")
	testing.expect(t, !same_command("just build", "just build"), "the same line")
	testing.expect_value(t, edit_distance("kitten", "sitting"), 3)
}

@(test)
lessons_lists_corrections_and_retries_and_proposes_them :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := recall_fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "recall", "--enable", "fixture")
	exec(f.cli, "recall", "--sync")

	o, _, code := exec(f.cli, "lessons")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, "no corrections or retries in the last 30 days"), o)

	o, _, code = exec(f.cli, "lessons", "--since", "9999d")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "    agent: I moved the filmstrip so the playhead lands on a seam\n    user: No, don't move the filmstrip"), o)
	testing.expect(t, strings.contains(o, "    failed: just build\n    worked: just build SAN=\n    c1\n"), o)

	o, _, code = exec(f.cli, "lessons", "--since", "9999d", "--project", "other")
	testing.expect_value(t, code, 1)

	o, _, code = exec(f.cli, "lessons", "--since", "9999d", "--json")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	arr, _ := v.(json.Array)
	testing.expect_value(t, len(arr), 2)
	if len(arr) == 2 {
		testing.expect_value(t, json_string(arr[0], "kind"), "correction")
		testing.expect_value(t, json_string(arr[0], "id"), "f4")
		testing.expect_value(t, json_string(arr[1], "kind"), "retry")
	}

	// Each moment becomes an inbox bullet sourced from its turn, once.
	o, _, code = exec(f.cli, "lessons", "--since", "9999d", "--propose")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "proposed #1 **lesson: no don't move the filmstrip move**"), o)
	testing.expect(t, strings.contains(o, "proposed #2 **retry: just build SAN=**"), o)
	o, _, code = exec(f.cli, "lessons", "--since", "9999d", "--propose", "--json")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "{\"moments\":2,\"proposed\":0}\n")
	o, _, code = exec(f.cli, "find", "filmstrip")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "recall:f4"), o)
}
