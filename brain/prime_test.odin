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
	// A prompt about nothing gets the hint once per session, then nothing.
	f.cli.stdin = `{"session_id":"s-two","hook_event_name":"UserPromptSubmit","prompt":"what is the weather"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect_value(t, o, "")
	f.cli.stdin = `{"session_id":"s-hint","hook_event_name":"UserPromptSubmit","prompt":"what is the weather"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect_value(t, o, PRIME_HINT)
	o, _, _ = exec(f.cli, "prime")
	testing.expect_value(t, o, "")
	// A fact only a note holds follows the bullets.
	f.cli.stdin = `{"session_id":"s-note","hook_event_name":"UserPromptSubmit","prompt":"later the git library is chosen?"}`
	o, _, _ = exec(f.cli, "prime")
	testing.expect(t, strings.contains(o, NOTES_HEAD) && strings.contains(o, "handoffs/"), o)
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

// Reading is not work: a session of lookups, greps and quietened commands
// is never asked; one that wrote, built or committed is.
@(test)
settle_counts_only_mutating_shell_as_work :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	reads := [?]string{"ls -la", "cat a.md | grep x", "brain find busctl 2>&1; echo ---; brain recall busctl 2>/dev/null", "rg -n TODO src >/dev/null"}
	for r in reads {
		testing.expect(t, !shell_mutates(r), r)
	}
	writes := [?]string{"echo hi > out.txt", "chmod +x run.sh", "sed -i 's/a/b/' f", "git commit -m x", "just release", "mkdir -p a/b"}
	for w in writes {
		testing.expect(t, shell_mutates(w), w)
	}
	tr := Transcript{tools = []Tool{{name = "Bash", input = "ls"}, {name = "Bash", input = "brain find x"}}}
	_, worked, proposed := settle_scan(tr)
	testing.expect(t, !worked && !proposed, "lookups alone are not work")
	tr = Transcript{tools = []Tool{{name = "Bash", input = "printf x > f"}, {name = "Bash", input = "brain propose '- **x** — y'"}}}
	_, worked, proposed = settle_scan(tr)
	testing.expect(t, worked && proposed, "a write is work and the proposal is seen")
}

@(test)
settle_asks_once_when_work_went_unproposed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	file := path.join(f.root, "t.jsonl")
	// The path is a JSON string, so a Windows path's backslashes are escaped.
	hook := proc(file, session: string, active: bool) -> string {
		return strings.concatenate({`{"session_id":"`, session, `","hook_event_name":"Stop","stop_hook_active":`, active ? "true" : "false", `,"transcript_path":"`, json_escape(file), `"}`})
	}
	f.cli.has_stdin = true

	// No work, or already proposed: nothing to say, however much was said.
	testing.expect_value(t, path.write(file, settle_transcript(8, false, false)), nil)
	f.cli.stdin = hook(file, "s1", false)
	o, _, code := exec(f.cli, "settle")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "")
	testing.expect_value(t, path.write(file, settle_transcript(8, true, true)), nil)
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")

	// Work without a proposal blocks the stop once, with the ask, however
	// short the session (at Stop the last reply is not even written yet).
	testing.expect_value(t, path.write(file, settle_transcript(2, true, false)), nil)
	o, _, code = exec(f.cli, "settle")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	testing.expect_value(t, json_string(v, "decision"), "block")
	testing.expect(t, strings.contains(json_string(v, "reason"), "brain propose"), o)
	testing.expect(t, strings.contains(json_string(v, "reason"), "This session wrote a."), o)
	testing.expect(t, os.exists(path.join(f.state, "settle", "s1")), "the session is stamped")
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")
	// A continuation after the block never blocks again.
	f.cli.stdin = hook(file, "s2", true)
	o, _, _ = exec(f.cli, "settle")
	testing.expect_value(t, o, "")
}

@(test)
hooks_turn_on_and_off_in_every_harness_here :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.env["BRAIN_EXE"] = "/opt/brain"
	// Claude Code is always here; pi only once its agent directory is.
	o, _, code := exec(f.cli, "hooks")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "claude  SessionStart       brain pack    off\nclaude  UserPromptSubmit   brain prime   off\nclaude  Stop               brain settle  off\n")
	testing.expect_value(t, path.mkdirs(path.join(f.home, ".pi", "agent")), nil)
	o, _, _ = exec(f.cli, "hooks")
	testing.expect(t, strings.has_suffix(o, "pi      agent_before_settle brain settle  off\n"), o)

	o, _, code = exec(f.cli, "hooks", "on")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "claude  Stop               brain settle  on\n"), o)
	testing.expect(t, strings.contains(o, "pi      before_agent_start brain prime   on\n"), o)
	text, _ := path.read(path.join(f.home, ".claude", "settings.json"))
	testing.expect(t, strings.contains(text, `"/opt/brain prime 2>/dev/null || true"`), text)
	ext, rerr := path.read(path.join(f.home, ".pi", "agent", "extensions", "brain.ts"))
	testing.expect_value(t, rerr, nil)
	testing.expect(t, strings.has_prefix(ext, PI_MARK) && strings.contains(ext, `const BRAIN = "/opt/brain";`), ext)
	testing.expect(t, strings.contains(ext, `"agent_before_settle"`) && strings.contains(ext, `["settle", "--harness", "pi"`), ext)
	o, _, _ = exec(f.cli, "hooks", "--json")
	testing.expect_value(t, o, `{"claude":{"pack":true,"prime":true,"settle":true},"pi":{"pack":true,"prime":true,"settle":true}}` + "\n")

	// Off for one harness leaves the other alone.
	o, _, code = exec(f.cli, "hooks", "off", "--harness", "pi")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "brain extension removed"), o)
	testing.expect(t, !os.exists(path.join(f.home, ".pi", "agent", "extensions", "brain.ts")), "the extension is gone")
	o, _, _ = exec(f.cli, "hooks")
	testing.expect(t, strings.contains(o, "claude  Stop               brain settle  on\n"), o)
	testing.expect(t, strings.contains(o, "pi      session_start      brain pack    off\n"), o)
	o, _, code = exec(f.cli, "hooks", "off")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "claude  Stop               brain settle  off\n"), o)
	_, _, code = exec(f.cli, "hooks", "sideways")
	testing.expect_value(t, code, 1)
	_, _, code = exec(f.cli, "hooks", "--harness", "codex")
	testing.expect_value(t, code, 1)
}

// pi passes the event as flags, not JSON: prime takes the prompt after
// --, settle the transcript, and the reply is the shape its extension
// reads.
@(test)
pi_harness_drives_prime_and_settle_by_flags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	f.cli.has_stdin = false
	o, _, code := exec(f.cli, "prime", "--harness", "pi", "--session", "pi-1", "--", "why", "does", "the", "sqlite", "index", "need", "fts5?")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "**sqlite**"), o)
	testing.expect_value(t, last_query_row(t, f), "1 pi pi-1")
	o, _, _ = exec(f.cli, "prime", "--harness", "pi", "--session", "pi-1", "--", "sqlite", "fts5")
	testing.expect_value(t, o, "")

	file := path.join(f.root, "pi.jsonl")
	testing.expect_value(t, path.write(file, pi_transcript(8, true, false)), nil)
	o, _, code = exec(f.cli, "settle", "--harness", "pi", "--session", "pi-1", "--transcript", file)
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	testing.expect(t, strings.contains(json_string(v, "reason"), "brain propose"), o)
	testing.expect(t, strings.contains(json_string(v, "reason"), "This session wrote a."), o)
	_, has_decision := v.(json.Object)["decision"]
	testing.expect(t, !has_decision, "pi's reply carries no Claude decision field")
	o, _, _ = exec(f.cli, "settle", "--harness", "pi", "--session", "pi-1", "--transcript", file)
	testing.expect_value(t, o, "")
	o, _, _ = exec(f.cli, "settle", "--harness", "pi", "--session", "pi-2", "--transcript", file, "--continuing")
	testing.expect_value(t, o, "")
	testing.expect(t, !wants_stdin({"prime", "--harness", "pi", "--session", "x", "--", "hi"}), "flags carry the event")
	testing.expect(t, wants_stdin({"settle"}), "a bare settle reads the hook's JSON")
}

// A pi session with n assistant turns, an edit when work is true and a
// brain propose call when propose is true; untitled, like a live one.
pi_transcript :: proc(turns: int, work, propose: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, `{"type":"session","version":3,"id":"pi-1","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/tmp/p"}` + "\n")
	strings.write_string(&b, `{"type":"message","id":"m0","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"start"}}` + "\n")
	for i in 0 ..< turns {
		strings.write_string(&b, `{"type":"message","id":"a`)
		strings.write_string(&b, int_str(i64(i)))
		strings.write_string(&b, `","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"working"}`)
		if work && i == 1 {
			strings.write_string(&b, `,{"type":"toolCall","id":"c1","name":"edit","arguments":{"path":"/tmp/p/a.odin","oldText":"x"}}`)
		}
		if propose && i == 2 {
			strings.write_string(&b, `,{"type":"toolCall","id":"c2","name":"bash","arguments":{"command":"brain propose '- **x** — y'"}}`)
		}
		strings.write_string(&b, "]}}\n")
	}
	return strings.to_string(b)
}
