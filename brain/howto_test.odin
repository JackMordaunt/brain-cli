package brain

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"

@(test)
howto_replays_the_chain_that_worked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := recall_fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "recall", "--enable", "fixture")
	exec(f.cli, "recall", "--sync")

	// The failed `just build` is dropped and the Edit is not a shell call.
	o, _, code := exec(f.cli, "howto", "build")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "2026-01-01  The playhead session  /tmp/omacut\n  just build SAN=\n  just test\n")

	o, _, code = exec(f.cli, "howto", "build", "--json")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	chain, _ := v.(json.Object)["chain"].(json.Array)
	testing.expect_value(t, len(chain), 2)
	if len(chain) == 2 {
		first, _ := chain[0].(json.String)
		second, _ := chain[1].(json.String)
		testing.expect_value(t, string(first), "just build SAN=")
		testing.expect_value(t, string(second), "just test")
	}

	o, _, code = exec(f.cli, "howto", "build", "--all")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "2 commands  sess-one"), o)

	o, _, code = exec(f.cli, "howto", "makepkg")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, "no session ran commands about"), o)

	// The chain lands in the repository's state folder with a bullet
	// pointing at it, which the next find answers.
	o, _, code = exec(f.cli, "howto", "build", "--propose")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "wrote omacut/howto-build.md"), o)
	testing.expect(t, strings.contains(o, "proposed #1 **howto build**"), o)
	text, rerr := os.read_entire_file_from_path(path.join(f.vault, "omacut", "howto-build.md"), context.allocator)
	testing.expect_value(t, rerr, nil)
	testing.expect(t, strings.contains(string(text), "```sh\njust build SAN=\njust test\n```"), string(text))
	o, _, code = exec(f.cli, "find", "howto", "build")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**howto build**") && strings.contains(o, "recall:sess-one"), o)
}
