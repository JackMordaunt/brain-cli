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
	testing.expect_value(t, o, "ingested 2 transcript(s)\nturns: 3\n")

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
			`{"type":"assistant","uuid":"a1","timestamp":"2026-01-01T10:00:01Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"},{"type":"tool_use","name":"x"}]}}` +
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
	turns := claude_emit(f.cli, file)
	testing.expect_value(t, len(turns), 2)
	testing.expect_value(t, turns[0].id, "u1")
	testing.expect_value(t, turns[0].body, "hello there friend")
	testing.expect_value(t, turns[0].cwd, `C:\Users\me\proj`)
	testing.expect_value(t, turns[0].title, "A titled session")
	testing.expect_value(t, turns[0].session, "abc-123")
	testing.expect_value(t, turns[1].role, "assistant")
	testing.expect_value(t, turns[1].body, "hi")

	// No title means a headless run, not a conversation.
	testing.expect_value(t, path.write(file, `{"type":"user","uuid":"u1","message":{"role":"user","content":"x"}}` + "\n"), nil)
	testing.expect_value(t, len(claude_emit(f.cli, file)), 0)
}
