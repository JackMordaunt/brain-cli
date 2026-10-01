package brain

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import "jm:path"

// recall runs against a fixture source, never anyone's real transcripts.
recall_fixture :: proc(t: ^testing.T) -> Fixture {
	f := fixture(t)
	cwd, _ := os.get_working_directory(context.allocator)
	f.cli.env["FIXTURE_TRANSCRIPTS"] = path.join(cwd, "testdata", "transcripts")
	f.cli.env["CLAUDE_CODE_SESSION_ID"] = ""
	f.cli.env["CLAUDE_SESSION_ID"] = ""
	return f
}

@(test)
recall_needs_an_enabled_source :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := recall_fixture(t)
	defer fixture_destroy(f)
	_, e, code := exec(f.cli, "recall", "playhead")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.contains(e, "no transcript sources enabled"), e)
	o: string
	o, _, code = exec(f.cli, "recall", "--sources")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "fixture  disabled"), o)
	o, _, code = exec(f.cli, "recall", "--enable", "fixture")
	testing.expect_value(t, code, 0)
	o, _, _ = exec(f.cli, "recall", "--sources")
	testing.expect(t, strings.contains(o, "fixture  enabled"), o)
	_, _, code = exec(f.cli, "recall", "--enable", "nope")
	testing.expect_value(t, code, 1)
}

@(test)
recall_finds_snippets_titles_and_sessions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := recall_fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "recall", "--enable", "fixture")
	o, _, code := exec(f.cli, "recall", "--sync")
	testing.expect_value(t, code, 0)
	testing.expect_value(t, o, "ingested 2 transcript(s)\nturns: 4\ntool calls: 4\n")

	o, _, code = exec(f.cli, "recall", "playhead")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "[playhead]"), "recall snippet")
	testing.expect(t, strings.contains(o, "The playhead session"), "recall title")
	testing.expect(t, !strings.contains(o, "makepkg"), "recall scoped")

	o, _, code = exec(f.cli, "recall", "playhead", "--exclude", "sess-one")
	testing.expect_value(t, code, 1)
	testing.expect(t, strings.has_prefix(o, "nothing said about"), "recall --exclude")

	o, _, code = exec(f.cli, "recall", "--full", "f1")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "frame you clicked"), "recall --full")

	o, _, code = exec(f.cli, "recall", "playhead", "--json")
	testing.expect_value(t, code, 0)
	v, jerr := json.parse_string(o)
	testing.expect_value(t, jerr, nil)
	arr, is_arr := v.(json.Array)
	testing.expect(t, is_arr && len(arr) > 0, "recall --json is an array")
	if is_arr && len(arr) > 0 {
		testing.expect_value(t, json_string(arr[0], "title"), "The playhead session")
	}

	o, _, code = exec(f.cli, "recall", "playhead", "--sessions")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "sess-one"), "recall --sessions")
	testing.expect_value(t, strings.count(o, "\n"), 1)

	_, _, code = exec(f.cli, "recall", "playh", "--sessions")
	testing.expect_value(t, code, 1)
	o, _, code = exec(f.cli, "recall", "playh", "--sessions", "--prefix")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(o, "sess-one"), "recall --prefix")
}

// Re-syncing the same fixture must not double-count: ids are the key.
@(test)
recall_sync_is_idempotent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := recall_fixture(t)
	defer fixture_destroy(f)
	exec(f.cli, "recall", "--enable", "fixture")
	before, _, _ := exec(f.cli, "recall", "--sync")
	after, _, _ := exec(f.cli, "recall", "--sync")
	testing.expect_value(t, after, before)
}

@(test)
claude_adapter_reads_a_transcript :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	file := path.join(f.root, "abc-123.jsonl")
	testing.expect_value(
		t,
		path.write(
			file,
			`{"type":"user","cwd":"C:\\Users\\me\\proj","isSidechain":false,"uuid":"u1","timestamp":"2026-01-01T10:00:00Z","message":{"role":"user","content":"hello   there\nfriend"}}` +
			"\n" +
			`{"type":"assistant","uuid":"a1","timestamp":"2026-01-01T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"x"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"just   build","description":"Build"}},{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/p/a.odin","old_string":"x"}}]}}` +
			"\n" +
			`{"type":"user","uuid":"r1","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"boom","is_error":true},{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}` +
			"\n" +
			`{"type":"user","uuid":"u2","isMeta":true,"message":{"role":"user","content":"meta"}}` +
			"\n" +
			`{"type":"user","uuid":"u3","message":{"role":"user","content":"<system-reminder>skip</system-reminder>"}}` +
			"\n" +
			`{"type":"custom-title","customTitle":"A titled session"}` +
			"\n",
		),
		nil,
	)
	tr := claude_emit(f.cli, file)
	turns := tr.turns
	testing.expect_value(t, len(turns), 2)
	// Two calls carried an id; the result marked the first an error.
	testing.expect_value(t, len(tr.tools), 2)
	if len(tr.tools) == 2 {
		testing.expect_value(t, tr.tools[0].name, "Bash")
		testing.expect_value(t, tr.tools[0].input, "just build")
		testing.expect_value(t, tr.tools[0].ok, false)
		testing.expect_value(t, tr.tools[0].turn_id, "a1")
		testing.expect_value(t, tr.tools[1].input, "/p/a.odin")
		testing.expect_value(t, tr.tools[1].ok, true)
	}
	testing.expect_value(t, turns[0].id, "u1")
	testing.expect_value(t, turns[0].body, "hello there friend")
	testing.expect_value(t, turns[0].cwd, `C:\Users\me\proj`)
	testing.expect_value(t, turns[0].title, "A titled session")
	testing.expect_value(t, turns[0].session, "abc-123")
	testing.expect_value(t, turns[1].role, "assistant")
	testing.expect_value(t, turns[1].body, "hi")

	// No title means a headless run, not a conversation.
	testing.expect_value(t, path.write(file, `{"type":"user","uuid":"u1","message":{"role":"user","content":"x"}}` + "\n"), nil)
	testing.expect_value(t, len(claude_emit(f.cli, file).turns), 0)
}

@(test)
pi_adapter_reads_tool_calls_and_their_results :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	f := fixture(t)
	defer fixture_destroy(f)
	file := path.join(f.root, "2026-01-01T00-00-00-000Z_pi-9.jsonl")
	testing.expect_value(
		t,
		path.write(
			file,
			`{"type":"session","version":3,"id":"pi-9","timestamp":"2026-01-01T00:00:00.000Z","cwd":"/tmp/p"}` +
			"\n" +
			`{"type":"message","id":"u1","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"build it"}}` +
			"\n" +
			`{"type":"message","id":"a1","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"on it"},{"type":"toolCall","id":"c1","name":"bash","arguments":{"command":"just  build"}},{"type":"toolCall","id":"c2","name":"read","arguments":{"path":"/tmp/p/x"}}]}}` +
			"\n" +
			`{"type":"message","id":"r1","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"toolResult","toolCallId":"c1","toolName":"bash","content":[{"type":"text","text":"boom"}],"isError":true}}` +
			"\n" +
			`{"type":"message","id":"r2","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"toolResult","toolCallId":"c2","toolName":"read","content":[{"type":"text","text":"ok"}],"isError":false}}` +
			"\n" +
			`{"type":"custom","id":"t1","timestamp":"2026-01-01T00:00:04.000Z","customType":"conversation-title","data":{"title":"A pi session"}}` +
			"\n",
		),
		nil,
	)
	tr := pi_emit(f.cli, file)
	testing.expect_value(t, len(tr.turns), 2)
	testing.expect_value(t, len(tr.tools), 2)
	if len(tr.tools) == 2 {
		testing.expect_value(t, tr.tools[0].name, "bash")
		testing.expect_value(t, tr.tools[0].input, "just build")
		testing.expect_value(t, tr.tools[0].ok, false)
		testing.expect_value(t, tr.tools[0].turn_id, "a1")
		testing.expect_value(t, tr.tools[0].session, "pi-9")
		testing.expect_value(t, tr.tools[1].input, "/tmp/p/x")
		testing.expect_value(t, tr.tools[1].ok, true)
	}
	if len(tr.turns) == 2 {
		testing.expect_value(t, tr.turns[0].title, "A pi session")
	}
	// Untitled, a scan still reads it and emit does not.
	testing.expect_value(t, path.write(file, `{"type":"session","version":3,"id":"pi-9","cwd":"/tmp/p"}` + "\n" + `{"type":"message","id":"u1","timestamp":"2026-01-01T00:00:01.000Z","message":{"role":"user","content":"x"}}` + "\n"), nil)
	testing.expect_value(t, len(pi_emit(f.cli, file).turns), 0)
	testing.expect_value(t, len(pi_scan(f.cli, file).turns), 1)
}
