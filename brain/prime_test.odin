package brain

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"

@(test)
prime_terms_drop_noise_and_pasted_text :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	terms := prime_terms("How do I rebuild the sqlite index? <pasted_content id=\"1\">\nlibgit2 everywhere\n</pasted_content id=\"1\"> please")
	testing.expect_value(t, strings.join(terms, " "), "rebuild sqlite index")
	testing.expect_value(t, len(prime_terms("do it now")), 0)
}

// A prompt's bullets are served once per session: the second prompt on
// the same topic, and a prompt after the pack served it, print nothing.
@(test)
prime_serves_each_bullet_once_per_session :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	hook := `{"session_id":"s-prime","hook_event_name":"UserPromptSubmit","prompt":"why does the sqlite index need fts5?","cwd":"/tmp"}`
	f.cli.stdin, f.cli.has_stdin = hook, true
	o, _, code := exec(f.cli, "prime")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_prefix(o, PRIME_HEAD), o)
	testing.expect(t, strings.contains(o, "**sqlite**") && !strings.contains(o, "libgit2"), o)
	testing.expect_value(t, last_query_row(t, f), "1 claude s-prime")

	o, _, code = exec(f.cli, "prime")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")

	// Another session is served; a prompt about nothing prints nothing.
	f.cli.stdin = `{"session_id":"s-two","hook_event_name":"UserPromptSubmit","prompt":"sqlite?"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect(t, strings.contains(o, "**sqlite**"), o)
	f.cli.stdin = `{"session_id":"s-two","hook_event_name":"UserPromptSubmit","prompt":"what is the weather"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect_value(t, o, "")
	// A sentence no bullet holds whole is answered by the bullets holding
	// enough of it; one shared word is not enough.
	f.cli.stdin = `{"session_id":"s-two","hook_event_name":"UserPromptSubmit","prompt":"which git library does the app bind, and does it shell out to a binary on PATH for the index?"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect(t, strings.contains(o, "**libgit2**") && !strings.contains(o, "**sqlite**"), o)

	// Typed at a terminal, the prompt is the arguments.
	f.cli.has_stdin = false
	f.cli.env["BRAIN_SESSION"] = "s-three"
	o, _, code = exec(f.cli, "prime", "the", "libgit2", "binding", "--json")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	hits, _ := v.(json.Object)["hits"].(json.Array)
	testing.expect_value(t, len(hits), 1)
	if len(hits) == 1 {
		testing.expect_value(t, json_string(hits[0], "handle"), "libgit2")
	}

	// The pack counts as served too.
	f.cli.env["BRAIN_SESSION"] = "s-four"
	o, _, _ = exec(f.cli, "pack", "fixture")
	testing.expect(t, strings.contains(o, "**fixture tool**"), o)
	o, _, _ = exec(f.cli, "prime", "fixture", "tool")
	testing.expect_value(t, o, "")
}

settle_transcript :: proc(turns: int, work, propose: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"user","uuid":"u0","message":{"role":"user","content":"start"}}` + "\n")
	for i in 0 ..< turns {
		strings.write_string(&b, `{"type":"assistant","uuid":"a`)
		strings.write_string(&b, int_str(i64(i)))
		strings.write_string(&b, `","message":{"role":"assistant","content":[{"type":"text","text":"working"}`)
		if work && i == 1 {
			strings.write_string(&b, `,{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/p/a"}}`)
		}
		if propose && i == 2 {
			strings.write_string(&b, `,{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"brain propose '- **x** — y'"}}`)
		}
		strings.write_string(&b, "]}}\n")
	}
	return strings.to_string(b)
}

@(test)
settle_asks_once_when_work_went_unproposed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	file := path.join(f.root, "t.jsonl")
	hook := proc(file, session: string, active: bool) -> string {
		return strings.concatenate({`{"session_id":"`, session, `","hook_event_name":"Stop","stop_hook_active":`, active ? "true" : "false", `,"transcript_path":"`, file, `"}`})
	}
	f.cli.has_stdin = true

	// Too short, no work, or already proposed: nothing to say.
	testing.expect_value(t, path.write(file, settle_transcript(3, true, false)), nil)
	f.cli.stdin = hook(file, "s1", false)
	o, _, code := exec(f.cli, "settle")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")
	testing.expect_value(t, path.write(file, settle_transcript(8, false, false)), nil)
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")
	testing.expect_value(t, path.write(file, settle_transcript(8, true, true)), nil)
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")

	// Work without a proposal blocks the stop once, with the ask.
	testing.expect_value(t, path.write(file, settle_transcript(8, true, false)), nil)
	o, _, code = exec(f.cli, "settle")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	testing.expect_value(t, json_string(v, "decision"), "block")
	testing.expect(t, strings.contains(json_string(v, "reason"), "brain propose"), o)
	testing.expect(t, os.exists(path.join(f.state, "settle", "s1")), "the session is stamped")
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")
	// A continuation after the block never blocks again.
	f.cli.stdin = hook(file, "s2", true)
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")
}

@(test)
hooks_turn_on_and_off :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["BRAIN_EXE"] = "/opt/brain"
	o, _, code := exec(f.cli, "hooks")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "SessionStart       brain pack    off\nUserPromptSubmit   brain prime   off\nStop               brain settle  off\n")
	o, _, code = exec(f.cli, "hooks", "on")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_suffix(o, "SessionStart       brain pack    on\nUserPromptSubmit   brain prime   on\nStop               brain settle  on\n"), o)
	text, _ := path.read(path.join(f.home, ".claude", "settings.json"))
	testing.expect(t, strings.contains(text, `"/opt/brain prime 2>/dev/null || true"`), text)
	o, _, _ = exec(f.cli, "hooks", "--json")
	testing.expect_value(t, o, `{"pack":true,"prime":true,"settle":true}` + "\n")
	o, _, code = exec(f.cli, "hooks", "off")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.has_suffix(o, "Stop               brain settle  off\n"), o)
	_, _, code = exec(f.cli, "hooks", "sideways")
	testing.expect_value(t, code, 1)
}
